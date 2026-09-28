import Foundation
import Security

struct SavedLogin: Identifiable, Hashable {
    var id: String { host + "\u{1}" + account }
    let host: String
    let account: String
    let modified: Date?
}

/// Passwords live in the macOS keychain as Internet passwords tagged with creator 'VOID'.
/// Void itself never writes them to disk.
enum KeychainStore {
    private static let creator = NSNumber(value: UInt32(0x564F_4944)) // 'VOID'

    /// The data-protection keychain needs a signed team identifier; ad-hoc builds fall back
    /// to the login keychain (which may re-prompt after each rebuild).
    private static var useDataProtection: Bool {
        get { UserDefaults.standard.object(forKey: "keychainDataProtection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keychainDataProtection") }
    }

    private static func base() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                kSecAttrCreator as String: creator]
        if useDataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    static func save(host: String, account: String, password: String) -> Bool {
        var query = base()
        query[kSecAttrServer as String] = host
        query[kSecAttrAccount as String] = account
        let data = Data(password.utf8)

        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(host) (Void)"
            add[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement && useDataProtection {
            useDataProtection = false
            return save(host: host, account: account, password: password)
        }
        return status == errSecSuccess
    }

    /// Accounts only — no secret is read, so no prompt.
    static func logins() -> [SavedLogin] {
        var query = base()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement && useDataProtection {
            useDataProtection = false
            return logins()
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String else { return nil }
            return SavedLogin(host: host, account: account, modified: item[kSecAttrModificationDate as String] as? Date)
        }.sorted { $0.host == $1.host ? $0.account < $1.account : $0.host < $1.host }
    }

    /// Logins usable on `host` (same host or parent/child domain).
    static func logins(matching host: String) -> [SavedLogin] {
        let h = host.voidNormalizedHost
        return logins().filter { login in
            let l = login.host.voidNormalizedHost
            return l == h || h.hasSuffix("." + l) || l.hasSuffix("." + h)
        }
    }

    /// Call only after BiometricGate succeeded.
    static func password(host: String, account: String) -> String? {
        var query = base()
        query[kSecAttrServer as String] = host
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ login: SavedLogin) {
        var query = base()
        query[kSecAttrServer as String] = login.host
        query[kSecAttrAccount as String] = login.account
        SecItemDelete(query as CFDictionary)
    }
}
