#if os(macOS)
import Foundation
import Security
import WebKit

/// The key WebKit wraps sites' stored CryptoKeys with (WebCrypto keys kept in IndexedDB by Google,
/// Proton, WhatsApp Web…). Left to itself, WebKit reads it from the login keychain at every wrap
/// and unwrap, never caching it, from an item ("Clé maîtresse WebCrypto Void") whose ACL demands
/// the session password from any build but the one that created it: a burst of password prompts.
///
/// Void answers instead (`_WKWebsiteDataStoreDelegate.webCryptoMasterKey:`, macOS 15+): the key
/// is read once per launch, from Void's own item, which macOS lets Void read without asking. The
/// first time, it is copied from WebKit's item (one prompt at most), so the keys sites already
/// stored still unwrap. With neither, a new key is made, the way WebKit does (16 random bytes).
@MainActor
final class WebCryptoMasterKey: NSObject {
    static let shared = WebCryptoMasterKey()

    private static let service = "app.void.browser.webcrypto"
    private static let account = "master"
    private static let keySize = 16

    private var key: Data?
    /// WebKit asks again while the keychain is being read (several frames at once): one read.
    private var waiting: [(Data?) -> Void] = []

    /// Makes Void the provider for `store`. The delegate property is weak: the shared instance
    /// keeps it alive.
    func attach(to store: WKWebsiteDataStore) {
        let setter = NSSelectorFromString("set_delegate:")
        guard store.responds(to: setter) else { return }
        store.perform(setter, with: self)
    }

    @objc(webCryptoMasterKey:)
    func webCryptoMasterKey(_ completionHandler: @escaping (Data?) -> Void) {
        if let key { return completionHandler(key) }
        waiting.append(completionHandler)
        guard waiting.count == 1 else { return }
        // Off the main thread: the read may wait on a keychain dialog.
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.fetch() }.value
            key = found
            let handlers = waiting
            waiting = []
            for handler in handlers { handler(found) }
        }
    }

    /// nil only if the keychain refused (WebKit then falls back to its own read).
    nonisolated private static func fetch() -> Data? {
        if let own = read([kSecAttrService as String: service, kSecAttrAccount as String: account]),
           own.count == keySize {
            return own
        }
        let webKitAccount = "com.apple.WebKit.WebCrypto.master+" + (Bundle.main.bundleIdentifier ?? "app.void.browser")
        var status: OSStatus = errSecSuccess
        if let stored = read([kSecAttrAccount as String: webKitAccount], status: &status) {
            // WebKit stores it base64-encoded.
            guard let legacy = Data(base64Encoded: stored), legacy.count == keySize else { return nil }
            store(legacy)
            return legacy
        }
        // Refused (or cancelled) rather than missing: a new key would orphan the stored ones.
        guard status == errSecItemNotFound else { return nil }
        var fresh = Data(count: keySize)
        let rc = fresh.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, keySize, $0.baseAddress!) }
        guard rc == errSecSuccess, store(fresh) else { return nil }
        return fresh
    }

    nonisolated private static func read(_ attributes: [String: Any]) -> Data? {
        var status: OSStatus = errSecSuccess
        return read(attributes, status: &status)
    }

    nonisolated private static func read(_ attributes: [String: Any], status: inout OSStatus) -> Data? {
        var query = attributes
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    /// Created by Void, so its ACL trusts Void's (stable) signature: read without a prompt.
    @discardableResult
    nonisolated private static func store(_ key: Data) -> Bool {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecAttrLabel as String: "Void WebCrypto",
                                   kSecAttrComment as String: String(localized: "Chiffre les clés WebCrypto que les sites gardent dans Void (IndexedDB)."),
                                   kSecAttrSynchronizable as String: false,
                                   kSecValueData as String: key]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
#endif
