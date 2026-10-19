import Foundation
import Security

struct SavedLogin: Identifiable, Hashable {
    var id: String { host + "\u{1}" + account }
    let host: String
    let account: String
    let modified: Date?
    /// Saved from an https page (and every import): never offered on a plain-HTTP page of a site on
    /// the Internet, where anyone on the network could read what is typed.
    var isSecure = true
}

/// Passwords live in the macOS keychain as Internet passwords tagged with creator 'VOID'.
/// Void itself never writes them to disk.
enum KeychainStore {
    private static let creator = NSNumber(value: UInt32(0x564F_4944)) // 'VOID'

    /// The data-protection keychain needs a keychain-access-groups entitlement (so a provisioning
    /// profile); without it, the login keychain. Its items trust Void's designated requirement:
    /// signed ad hoc, that's the binary's hash, so every rebuild would prompt again for each item
    /// — hence the Apple Development signature, whose requirement survives rebuilds.
    private static var useDataProtection: Bool {
        get { UserDefaults.standard.object(forKey: "keychainDataProtection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keychainDataProtection") }
    }

    /// The accounts (no secrets), read once: every login form a page shows asks for them.
    /// Dropped at each change. Imports write from a background thread, hence the lock.
    private static let cacheLock = NSLock()
    private static var cachedLogins: [SavedLogin]?

    private static func invalidateCache() {
        cacheLock.lock()
        cachedLogins = nil
        cacheLock.unlock()
    }

    private static func base() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                kSecAttrCreator as String: creator]
        if useDataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// `secure`: the page the password was typed on was https (plain HTTP is recorded as such).
    static func save(host: String, account: String, password: String, secure: Bool = true) -> Bool {
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
            add[kSecAttrProtocol as String] = secure ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement && useDataProtection {
            useDataProtection = false
            return save(host: host, account: account, password: password, secure: secure)
        }
        if status == errSecSuccess { invalidateCache() }
        return status == errSecSuccess
    }

    /// Accounts only — no secret is read, so no prompt.
    static func logins() -> [SavedLogin] {
        cacheLock.lock()
        let cached = cachedLogins
        cacheLock.unlock()
        if let cached { return cached }
        let fresh = readLogins()
        cacheLock.lock()
        cachedLogins = fresh
        cacheLock.unlock()
        return fresh
    }

    private static func readLogins() -> [SavedLogin] {
        var query = base()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement && useDataProtection {
            useDataProtection = false
            return readLogins()
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String else { return nil }
            let http = (item[kSecAttrProtocol as String] as? String) == (kSecAttrProtocolHTTP as String)
            return SavedLogin(host: host, account: account, modified: item[kSecAttrModificationDate as String] as? Date, isSecure: !http)
        }.sorted { $0.host == $1.host ? $0.account < $1.account : $0.host < $1.host }
    }

    /// Domains where each subdomain is someone else's site (pages, blogs, apps hosted for anyone):
    /// there a login is offered on its own host only, never on its neighbours.
    static let sharedHostingSuffixes = ["github.io", "gitlab.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app",
                                        "herokuapp.com", "web.app", "firebaseapp.com", "appspot.com", "blogspot.com",
                                        "wordpress.com", "tumblr.com", "glitch.me", "onrender.com", "fly.dev", "repl.co",
                                        "azurewebsites.net", "cloudfront.net", "s3.amazonaws.com", "neocities.org", "wixsite.com"]

    private static func isSharedHosting(_ host: String) -> Bool {
        sharedHostingSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Logins usable on `host` (same host, or parent/child domain outside shared hosting).
    /// `secure`: the page is https. On a plain-HTTP page of an Internet site, only logins saved
    /// over HTTP; a local device (router, intranet) keeps getting its logins.
    static func logins(matching host: String, secure: Bool = true) -> [SavedLogin] {
        let h = host.voidNormalizedHost
        let plainInternet = !secure && !LocalNetwork.isLocal(h)
        return logins().filter { login in
            if plainInternet && login.isSecure { return false }
            let l = login.host.voidNormalizedHost
            if l == h { return true }
            if isSharedHosting(l) || isSharedHosting(h) { return false }
            return h.hasSuffix("." + l) || l.hasSuffix("." + h)
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
        invalidateCache()
    }
}
