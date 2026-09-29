import AppKit
import LocalAuthentication
import WebKit

/// Touch ID (or the Mac's password as fallback) before any password is revealed or filled.
@MainActor
enum BiometricGate {
    private static var lastSuccess: Date?

    static func authenticate(reason: String) async -> Bool {
        if let lastSuccess, Date().timeIntervalSince(lastSuccess) < 60 { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { lastSuccess = Date() }
            return ok
        } catch {
            return false
        }
    }
}

/// Glue between autofill.js, the keychain and the UI.
@MainActor
final class PasswordManager {
    static let shared = PasswordManager()

    func handle(_ body: [String: Any], frame: WKFrameInfo, tab: Tab) {
        // The frame's security origin, not what the script reports: it is what WebKit enforces.
        let originHost = frame.securityOrigin.host.voidNormalizedHost
        guard let type = body["type"] as? String, !originHost.isEmpty else { return }
        let host = originHost
        switch type {
        case "form":
            let accounts = KeychainStore.logins(matching: host)
            // Prefer the main frame's form when several frames report one.
            if tab.loginFrame == nil || frame.isMainFrame || !accounts.isEmpty {
                tab.loginFrame = frame
                tab.loginHost = host
                tab.loginAccounts = accounts.map(\.account)
            }
        case "submit":
            guard !tab.isPrivate,
                  !AppSettings.shared.neverSavePasswordHosts.contains(host),
                  let password = body["password"] as? String, !password.isEmpty else { return }
            let username = body["username"] as? String ?? ""
            let known = KeychainStore.logins(matching: host).contains { $0.account == username }
            if known, KeychainStore.password(host: host, account: username) == password { return }
            (tab.browser ?? .shared).passwordPrompt = PasswordSavePrompt(host: host, username: username, password: password)
        default:
            break
        }
    }

    func save(_ prompt: PasswordSavePrompt, in browser: BrowserModel) {
        if KeychainStore.save(host: prompt.host, account: prompt.username, password: prompt.password) {
            browser.showToast("key.fill", "Mot de passe enregistré dans le trousseau")
        } else {
            browser.showToast("exclamationmark.triangle", "Impossible d'enregistrer dans le trousseau")
        }
        browser.passwordPrompt = nil
        if let tab = browser.selectedTab, tab.loginHost == prompt.host,
           !tab.loginAccounts.contains(prompt.username) {
            tab.loginAccounts.append(prompt.username)
        }
    }

    func neverForHost(_ prompt: PasswordSavePrompt, in browser: BrowserModel) {
        AppSettings.shared.neverSavePasswordHosts.append(prompt.host)
        browser.passwordPrompt = nil
    }

    func fill(_ tab: Tab, account: String) async {
        guard tab.webView != nil, let host = tab.loginHost else { return }
        guard let login = KeychainStore.logins(matching: host).first(where: { $0.account == account }) else { return }
        guard await BiometricGate.authenticate(reason: "remplir le mot de passe de \(login.host)") else { return }
        guard let password = KeychainStore.password(host: login.host, account: login.account) else { return }
        if await inject(account: account, password: password, into: tab) != "ok" {
            tab.browser?.showToast("exclamationmark.triangle", "Formulaire de connexion introuvable")
        }
    }

    /// Writes the credentials into the frame whose form was detected, and only if that frame
    /// still has the origin they belong to (autofill.js checks it right before writing).
    /// There is deliberately no fallback to the main frame: it may belong to another site.
    func inject(account: String, password: String, into tab: Tab) async -> String? {
        guard let webView = tab.webView, let host = tab.loginHost else { return nil }
        let frame = tab.loginFrame
        let expectedProtocol = frame.map { $0.securityOrigin.protocol + ":" } ?? ""
        return await webView.voidCall("return window.__voidAutofill ? window.__voidAutofill.fill(u, p, h, pr) : 'fail';",
                                      arguments: ["u": account, "p": password, "h": host, "pr": expectedProtocol],
                                      in: frame) as? String
    }
}
