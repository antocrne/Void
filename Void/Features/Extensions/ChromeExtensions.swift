import Foundation

/// Where Chrome extensions come from: the Chrome Web Store, .crx files, and the extensions
/// already installed in another Chromium browser (Chrome, Brave, Edge, Arc).
enum ChromeExtensions {
    enum Failure: LocalizedError {
        case notAnExtensionLink, notACRX, download(String), unzip, symbolicLink

        var errorDescription: String? {
            switch self {
            case .notAnExtensionLink: String(localized: "Ce n'est pas un lien d'extension du Chrome Web Store (ni un identifiant d'extension).")
            case .notACRX: String(localized: "Ce fichier n'est pas une extension Chrome (.crx) lisible.")
            case .download(let reason): String(localized: "Téléchargement depuis le Chrome Web Store impossible : \(reason)")
            case .unzip: String(localized: "L'archive de l'extension n'a pas pu être décompressée.")
            case .symbolicLink: String(localized: "L'extension contient des liens symboliques : elle n'est pas chargée.")
            }
        }
    }

    /// A Chrome extension ID: 32 letters from a to p.
    static func isID(_ text: Substring) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The extension ID in a Chrome Web Store link (chromewebstore.google.com/detail/name/ID,
    /// chrome.google.com/webstore/detail/name/ID), or a bare ID.
    static func extensionID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isID(Substring(text)) { return text }
        guard let url = URL(string: text), let host = url.host()?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        return url.pathComponents.reversed().first { isID(Substring($0)) }
    }

    /// Whether a page is an extension's page on the Chrome Web Store (its "Add" button is Chrome-only).
    static func webStoreExtensionID(on url: URL?) -> String? {
        guard let url, url.path().contains("/detail/") else { return nil }
        return extensionID(from: url.absoluteString)
    }

    /// Google's update service answers with the extension's latest .crx.
    static func webStoreDownloadURL(id: String) -> URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            // Above any extension's minimum_chrome_version: the store serves its latest version.
            URLQueryItem(name: "prodversion", value: "150.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        return components.url!
    }

    static func downloadFromWebStore(id: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: webStoreDownloadURL(id: id))
        guard let http = response as? HTTPURLResponse else { throw Failure.download(String(localized: "pas de réponse")) }
        guard http.statusCode == 200 else {
            throw Failure.download(http.statusCode == 204 || http.statusCode == 404
                                   ? String(localized: "extension introuvable ou retirée du store")
                                   : String(localized: "erreur \(http.statusCode)"))
        }
        guard !data.isEmpty else { throw Failure.download(String(localized: "extension introuvable ou retirée du store")) }
        return data
    }

    /// The zip archive inside a .crx: after a CRX3 header ("Cr24", 3, header size, header) or a
    /// CRX2 one ("Cr24", 2, key size, signature size, key, signature). A bare zip is kept as is.
    /// The signature isn't checked: the file comes from the store over HTTPS, or from the user.
    static func zipData(fromCRX data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(16))
        func uint32(at offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return data }
        guard bytes.count >= 16, bytes.starts(with: Array("Cr24".utf8)) else { throw Failure.notACRX }
        let start: Int
        switch uint32(at: 4) {
        case 3: start = 12 + uint32(at: 8)
        case 2: start = 16 + uint32(at: 8) + uint32(at: 12)
        default: throw Failure.notACRX
        }
        guard start < data.count else { throw Failure.notACRX }
        let zip = data.subdata(in: data.startIndex + start ..< data.endIndex)
        guard zip.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw Failure.notACRX }
        return zip
    }

    /// An extension's folder must hold only its own files: a symbolic link (kept by ditto and by
    /// copies) could make a file Void writes there, or one WebKit serves, point anywhere on the Mac.
    static func rejectSymbolicLinks(in folder: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: keys))?.isSymbolicLink == true { throw Failure.symbolicLink }
        }
    }

    /// Unpacks a zip into `folder` (created), with the system's ditto.
    static func unzip(_ zip: URL, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, folder.path]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw Failure.unzip }
    }

    // MARK: - Other Chromium browsers

    struct Installed: Identifiable, Hashable {
        let id: String
        let name: String
        let version: String
        let folder: URL
    }

    /// Extensions in the browser's profile (Extensions/<id>/<version>/), the latest version of each.
    /// Chrome's own hidden components have no manifest name and are left out.
    static func installed(in browser: SourceBrowser) -> [Installed] {
        guard browser.isChromium, let profile = browser.profileFolder else { return [] }
        let fm = FileManager.default
        let root = profile.appendingPathComponent("Extensions")
        let ids = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.filter { isID(Substring($0)) }.compactMap { id -> Installed? in
            let versions = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(id).path)) ?? []
            guard let version = versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last else { return nil }
            let folder = root.appendingPathComponent(id).appendingPathComponent(version)
            guard let manifest = manifest(in: folder), let name = displayName(manifest, in: folder), !name.isEmpty else { return nil }
            return Installed(id: id, name: name, version: manifest["version"] as? String ?? version, folder: folder)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func manifest(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The manifest's name, resolving "__MSG_key__" from _locales (French first, then the default locale).
    static func displayName(_ manifest: [String: Any], in folder: URL) -> String? {
        guard let name = manifest["name"] as? String else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
        let key = String(name.dropFirst(6).dropLast(2)).lowercased()
        let locales = ["fr", manifest["default_locale"] as? String, "en"].compactMap { $0 }
        for locale in locales {
            let file = folder.appendingPathComponent("_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let messages = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
               let message = entry["message"] as? String {
                return message
            }
        }
        return nil
    }
}
