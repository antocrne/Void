import Foundation
import CommonCrypto
import Security

enum SourceBrowser: String, CaseIterable, Identifiable {
    case chrome, arc, brave, edge, firefox
    var id: String { rawValue }

    var name: String {
        switch self {
        case .chrome: "Google Chrome"
        case .arc: "Arc"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .firefox: "Firefox"
        }
    }

    var isChromium: Bool { self != .firefox }

    private var supportFolder: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        switch self {
        case .chrome: return base.appendingPathComponent("Google/Chrome")
        case .arc: return base.appendingPathComponent("Arc/User Data")
        case .brave: return base.appendingPathComponent("BraveSoftware/Brave-Browser")
        case .edge: return base.appendingPathComponent("Microsoft Edge")
        case .firefox: return base.appendingPathComponent("Firefox/Profiles")
        }
    }

    /// Keychain item holding the key that encrypts Chromium passwords.
    var safeStorageService: String? {
        switch self {
        case .chrome: "Chrome Safe Storage"
        case .arc: "Arc Safe Storage"
        case .brave: "Brave Safe Storage"
        case .edge: "Microsoft Edge Safe Storage"
        case .firefox: nil
        }
    }

    /// The most relevant profile folder, if the browser is installed.
    var profileFolder: URL? {
        let fm = FileManager.default
        if isChromium {
            let def = supportFolder.appendingPathComponent("Default")
            if fm.fileExists(atPath: def.path) { return def }
            let profiles = (try? fm.contentsOfDirectory(at: supportFolder, includingPropertiesForKeys: nil)) ?? []
            return profiles.first { $0.lastPathComponent.hasPrefix("Profile ") }
        }
        let profiles = (try? fm.contentsOfDirectory(at: supportFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let usable = profiles.filter { fm.fileExists(atPath: $0.appendingPathComponent("places.sqlite").path) }
        return usable.first { $0.lastPathComponent.hasSuffix(".default-release") } ?? usable.first
    }

    var isInstalled: Bool { profileFolder != nil }
}

struct ImportResult {
    var bookmarks = 0
    var history = 0
    var passwords = 0
    var notes: [String] = []

    var summary: String {
        var parts = ["\(bookmarks) favoris", "\(history) pages d'historique", "\(passwords) mots de passe"]
        parts.append(contentsOf: notes)
        return parts.joined(separator: " · ")
    }
}

/// Imports bookmarks, history and passwords from other browsers' profile files.
@MainActor
enum BrowserImporter {
    static func run(from browser: SourceBrowser, bookmarks: Bool, history: Bool, passwords: Bool) -> ImportResult {
        var result = ImportResult()
        guard let profile = browser.profileFolder else {
            result.notes.append("\(browser.name) introuvable")
            return result
        }
        if bookmarks {
            let items = browser.isChromium ? chromiumBookmarks(profile, browser: browser) : firefoxBookmarks(profile)
            result.bookmarks = BookmarkStore.shared.importBookmarks(items)
        }
        if history {
            let entries = browser.isChromium ? chromiumHistory(profile) : firefoxHistory(profile)
            HistoryStore.shared.importEntries(entries)
            result.history = entries.count
        }
        if passwords {
            if browser.isChromium {
                let (count, note) = chromiumPasswords(profile, browser: browser)
                result.passwords = count
                if let note { result.notes.append(note) }
            } else {
                result.notes.append("Firefox chiffre ses mots de passe avec NSS : exportez-les en CSV (about:logins → ⋯ → Exporter) puis utilisez « Importer un CSV »")
            }
        }
        return result
    }

    // MARK: - Chromium

    private static func chromiumBookmarks(_ profile: URL, browser: SourceBrowser) -> [Bookmark] {
        var out: [Bookmark] = []
        if let data = try? Data(contentsOf: profile.appendingPathComponent("Bookmarks")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let roots = json["roots"] as? [String: Any] {
            func walk(_ node: [String: Any], folder: String?) {
                if node["type"] as? String == "url", let s = node["url"] as? String, let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
                    out.append(Bookmark(title: node["name"] as? String ?? s, url: url, folder: folder))
                }
                for child in node["children"] as? [[String: Any]] ?? [] {
                    walk(child, folder: node["type"] as? String == "folder" ? (node["name"] as? String) : folder)
                }
            }
            for case let root as [String: Any] in roots.values { walk(root, folder: nil) }
        }
        if browser == .arc {
            // Arc keeps its sidebar (pinned/favorites) outside of the Chromium profile.
            let sidebar = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
            if let data = try? Data(contentsOf: sidebar), let json = try? JSONSerialization.jsonObject(with: data) {
                func walk(_ any: Any) {
                    if let dict = any as? [String: Any] {
                        if let s = dict["savedURL"] as? String, let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
                            out.append(Bookmark(title: dict["savedTitle"] as? String ?? s, url: url, folder: "Arc"))
                        }
                        dict.values.forEach(walk)
                    } else if let array = any as? [Any] {
                        array.forEach(walk)
                    }
                }
                walk(json)
            }
        }
        return out
    }

    private static func chromiumHistory(_ profile: URL) -> [HistoryEntry] {
        guard let db = openCopy(profile.appendingPathComponent("History")) else { return [] }
        var out: [HistoryEntry] = []
        db.query("SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 5000") { row in
            guard let url = URL(string: row.string(0)), url.scheme?.hasPrefix("http") == true else { return }
            // WebKit/Chrome time: microseconds since 1601-01-01.
            let date = Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000 - 11_644_473_600)
            out.append(HistoryEntry(url: url, title: row.string(1), visits: Int(row.int(2)), lastVisit: date))
        }
        return out
    }

    private static func chromiumPasswords(_ profile: URL, browser: SourceBrowser) -> (Int, String?) {
        guard let service = browser.safeStorageService else { return (0, nil) }
        guard let key = ChromiumCrypto.key(service: service) else {
            return (0, "Accès refusé à « \(service) » dans le trousseau")
        }
        guard let db = openCopy(profile.appendingPathComponent("Login Data")) else { return (0, "Base « Login Data » illisible") }
        var count = 0
        var failures = 0
        db.query("SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0") { row in
            guard let host = URL(string: row.string(0))?.host(), !host.isEmpty else { return }
            guard let password = ChromiumCrypto.decrypt(row.data(2), key: key), !password.isEmpty else { failures += 1; return }
            if KeychainStore.save(host: host.voidNormalizedHost, account: row.string(1), password: password) { count += 1 }
        }
        return (count, failures > 0 ? "\(failures) mots de passe non déchiffrables" : nil)
    }

    // MARK: - Firefox

    private static func firefoxBookmarks(_ profile: URL) -> [Bookmark] {
        guard let db = openCopy(profile.appendingPathComponent("places.sqlite")) else { return [] }
        var out: [Bookmark] = []
        db.query("""
        SELECT b.title, p.url, parent.title FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id
        LEFT JOIN moz_bookmarks parent ON b.parent = parent.id WHERE b.type = 1 AND p.url LIKE 'http%'
        """) { row in
            guard let url = URL(string: row.string(1)) else { return }
            let folder = row.string(2)
            out.append(Bookmark(title: row.string(0).isEmpty ? row.string(1) : row.string(0), url: url, folder: folder.isEmpty ? nil : folder))
        }
        return out
    }

    private static func firefoxHistory(_ profile: URL) -> [HistoryEntry] {
        guard let db = openCopy(profile.appendingPathComponent("places.sqlite")) else { return [] }
        var out: [HistoryEntry] = []
        db.query("""
        SELECT url, COALESCE(title, ''), visit_count, last_visit_date FROM moz_places
        WHERE last_visit_date IS NOT NULL AND url LIKE 'http%' ORDER BY last_visit_date DESC LIMIT 5000
        """) { row in
            guard let url = URL(string: row.string(0)) else { return }
            out.append(HistoryEntry(url: url, title: row.string(1), visits: Int(row.int(2)),
                                    lastVisit: Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000)))
        }
        return out
    }

    // MARK: - CSV (any browser: Chrome, Firefox, Safari, Bitwarden… exports)

    static func importPasswordCSV(_ file: URL) -> Int {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.lowercased() }) else { return 0 }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let urlCol = column(["url", "origin", "login_uri", "website"]),
              let userCol = column(["username", "login", "login_username", "user"]),
              let passCol = column(["password", "login_password"]) else { return 0 }
        var count = 0
        for row in rows.dropFirst() where row.count > max(urlCol, userCol, passCol) {
            let raw = row[urlCol]
            guard let host = (URL(string: raw)?.host() ?? URL(string: "https://" + raw)?.host()), !row[passCol].isEmpty else { continue }
            if KeychainStore.save(host: host.voidNormalizedHost, account: row[userCol], password: row[passCol]) { count += 1 }
        }
        return count
    }

    // MARK: - Helpers

    /// Browsers keep their databases locked while running: work on a temporary copy.
    private static func openCopy(_ file: URL) -> SQLiteDB? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return nil }
        let dir = fm.temporaryDirectory.appendingPathComponent("void-import-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(file.lastPathComponent)
        do { try fm.copyItem(at: file, to: copy) } catch { return nil }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: file.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        return SQLiteDB(path: copy.path)
    }
}

/// Chromium on macOS: AES-128-CBC, key = PBKDF2-SHA1(Safe Storage secret, "saltysalt", 1003), IV = 16 spaces, prefix "v10".
enum ChromiumCrypto {
    static func key(service: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let secret = result as? Data else { return nil }
        var derived = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                secret.withUnsafeBytes { secretBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         secretBytes.bindMemory(to: Int8.self).baseAddress, secret.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         out.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    static func decrypt(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else {
            return String(data: blob, encoding: .utf8) // very old, unencrypted entries
        }
        let payload = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        var moved = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { inBytes in
                iv.withUnsafeBytes { ivBytes in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, payload.count, outBytes.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: out.prefix(moved), encoding: .utf8)
    }
}

enum CSV {
    /// RFC 4180-ish parser (quoted fields, escaped quotes, CRLF).
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else { field.append(c) }
                continue
            }
            switch c {
            case "\"": inQuotes = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n", "\r":
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            default: field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
