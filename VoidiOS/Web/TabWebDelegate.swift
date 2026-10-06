import UIKit
import WebKit

/// Navigation + UI delegate of one tab's web view (iOS). Same rules as the Mac's; dialogs are
/// alerts over the browser, and the link menu is the one iOS shows on touch and hold.
@MainActor
final class TabWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var tab: Tab?
    /// The browser owning the tab (private browsing keeps links and pop-ups private).
    private var browser: BrowserModel { tab?.browser ?? .shared }

    init(tab: Tab) { self.tab = tab }

    private static let internalSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "view-source"]

    /// Dialogs only over the tab being shown: one from a hidden tab would cover another page.
    private var isShown: Bool {
        guard let tab, let browser = tab.browser else { return false }
        return browser.selectedTab === tab && BrowserWindows.shared.active === browser
    }

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload {
            return await mayDownload(navigationAction.request.url, in: webView) ? .download : .cancel
        }
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""

        if !Self.internalSchemes.contains(scheme) {
            // mailto:, tel:, an app's own scheme… → handed over to iOS, only on a user tap in the
            // page itself, and after asking for anything but the usual system apps.
            let policy = ExternalURLPolicy.decide(scheme: scheme, userClick: navigationAction.navigationType == .linkActivated,
                                                  fromMainFrame: navigationAction.sourceFrame.isMainFrame)
            switch policy {
            case .open:
                _ = await UIApplication.shared.open(url)
            case .ask:
                let host = navigationAction.sourceFrame.securityOrigin.host
                if isShown, await Dialogs.confirm(title: "Ouvrir dans une autre app ?",
                                                  message: "\(host.isEmpty ? "Cette page" : host) veut ouvrir un lien « \(scheme): » dans une autre app.",
                                                  confirm: "Ouvrir") == true {
                    if await !UIApplication.shared.open(url) {
                        browser.showToast("exclamationmark.triangle", "Aucune app pour ouvrir ce lien")
                    }
                }
            case .refuse:
                break
            }
            return .cancel
        }

        // ⌘-tap with a keyboard (iPad) → new tab, ⌘⇧ in the foreground. Only a tap made in this very page.
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame != nil,
           navigationAction.sourceFrame.webView === webView {
            let flags = Self.modifiers(of: navigationAction)
            if flags.contains(.command) {
                browser.openTab(url: url, background: !flags.contains(.shift), after: tab)
                return .cancel
            }
        }
        return .allow
    }

    /// Keys held during the tap (a keyboard on iPad). WebKit reports them from iOS 18.4.
    private static func modifiers(of action: WKNavigationAction) -> UIKeyModifierFlags {
        if #available(iOS 18.4, *) { return action.modifierFlags }
        return []
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        var download = !navigationResponse.canShowMIMEType
        // "attachment" in any frame: Google Drive and others download through a hidden frame,
        // where a PDF or an image would otherwise be shown to nobody.
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            download = true
        }
        guard download else { return .allow }
        let response = navigationResponse.response
        return await mayDownload(response.url, file: response.suggestedFilename, in: webView) ? .download : .cancel
    }

    /// Asked once per site (DownloadPermission). A refused download leaves no empty tab behind.
    private func mayDownload(_ url: URL?, file: String? = nil, in webView: WKWebView) async -> Bool {
        // A tab opened for the file has no page yet: the site is the one that opened it.
        let opener = webView.backForwardList.currentItem == nil ? tab?.openerHost : nil
        let host = (opener ?? webView.url?.host() ?? url?.host() ?? "").voidNormalizedHost
        let file = file ?? url?.lastPathComponent
        let allowed = await DownloadPermission.request(host, file: file, in: browser)
        if !allowed {
            browser.showToast("arrow.down.circle", "Téléchargement refusé depuis \(host)")
            closeIfEmpty(webView)
        }
        return allowed
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, from: navigationAction.request.url, in: browser)
        closeIfEmpty(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, from: navigationResponse.response.url, in: browser)
        closeIfEmpty(webView)
    }

    /// Camera and microphone (video calls), asked once per site.
    /// The async name WebKit looks for (WKUIDelegate.h): under any other name it never calls this
    /// and refuses every request by itself.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard isShown else { return .deny }
        let host = origin.host.voidNormalizedHost
        let isPrivate = browser.isPrivate
        return await MediaPermission.decide(host: host, type: type, in: browser) {
            await Dialogs.confirm(title: "Autoriser « \(host) » à utiliser \(MediaPermission.devices(type)) ?",
                                  message: "Jusqu'à ce que vous quittiez Void" + (isPrivate ? " ou la navigation privée." : "."),
                                  confirm: "Autoriser", cancel: "Refuser") ?? false
        }
    }

    /// A link opened in a new tab that turned out to be a download leaves an empty tab behind.
    func closeIfEmpty(_ webView: WKWebView) {
        guard let tab, !tab.isPinned, webView.backForwardList.currentItem == nil else { return }
        browser.close(tab, force: true)
    }

    // MARK: - Navigation progress

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.loadError = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab else { return }
        tab.didCommit(webView.url)
        tab.reader = nil
        tab.loginAccounts = []
        tab.loginHost = nil
        tab.loginFrame = nil
        tab.readingProgress = 0
        tab.hasUserInput = false
        PiPController.shared.resetFrames(of: tab)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab else { return }
        if !tab.isPrivate, !browser.isEphemeralSession, let url = webView.url {
            HistoryStore.shared.record(url: url, title: webView.title ?? "")
            tab.lastRecordedURL = url
        }
        FaviconLoader.load(for: tab)
        tab.restorePendingScroll()
        browser.setNeedsSave()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        // Cancelled / interrupted by policy (downloads, links handed to another app) are not errors.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        tab?.loadError = ns.localizedDescription
    }

    // MARK: - HTTP authentication

    private static let passwordMethods: Set<String> = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                                                      NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodDefault]

    /// Sites behind HTTP authentication (routers, NAS, intranets): without this, WebKit never asks
    /// and shows the server's 401 page.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard Self.passwordMethods.contains(space.authenticationMethod), challenge.previousFailureCount < 3, isShown else {
            return (.performDefaultHandling, nil)
        }
        let port = [80, 443].contains(space.port) ? "" : ":\(space.port)"
        var info = space.realm.map { "« \($0) » demande un nom d'utilisateur et un mot de passe." }
            ?? "Ce site demande un nom d'utilisateur et un mot de passe."
        if challenge.previousFailureCount > 0 { info = "Nom d'utilisateur ou mot de passe incorrect. " + info }
        if !space.receivesCredentialSecurely { info += "\n\nLa connexion n'est pas chiffrée : le mot de passe sera envoyé en clair." }
        let fields = [Dialogs.Field(placeholder: "Nom d'utilisateur", text: challenge.proposedCredential?.user ?? ""),
                      Dialogs.Field(placeholder: "Mot de passe", secure: true)]
        guard let answer = await Dialogs.prompt(title: "Connexion à \(space.host)\(port)", message: info, fields: fields, confirm: "Se connecter"),
              answer.count == 2 else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(user: answer[0], password: answer[1], persistence: .forSession))
    }

    /// Last automatic reload after a crash of the page's process (at most one per 30 s).
    private var lastCrashReload: Date?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab else { return }
        // Not shown (iOS reclaims the memory of pages in the background): it comes back when selected.
        guard isShown else { tab.sleepAfterCrash(); return }
        if let last = lastCrashReload, Date().timeIntervalSince(last) < 30 {
            tab.isLoading = false
            tab.loadError = "La page a cessé de fonctionner."
            return
        }
        lastCrashReload = Date()
        webView.reload()
    }

    // MARK: - New windows → new tabs

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let flags = Self.modifiers(of: navigationAction)
        let background = flags.contains(.command) && !flags.contains(.shift)
        let newTab = browser.openTab(url: nil, background: background, after: tab, popupConfiguration: configuration)
        newTab.url = navigationAction.request.url
        newTab.openerHost = webView.url?.host()
        return newTab.ensureWebView()
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab { browser.close(tab, force: true) }
    }

    // MARK: - Link menu (touch and hold)

    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        let link = elementInfo.linkURL
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            guard let self, let link, let scheme = link.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                return UIMenu(children: suggested)
            }
            var actions: [UIMenuElement] = [
                UIAction(title: "Ouvrir dans un nouvel onglet", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    guard let self else { return }
                    self.browser.openTab(url: link, after: self.tab)
                },
                UIAction(title: "Ouvrir en arrière-plan", image: UIImage(systemName: "square.stack")) { [weak self] _ in
                    guard let self else { return }
                    self.browser.openTab(url: link, background: true, after: self.tab)
                    self.browser.showToast("square.stack", "Onglet ouvert en arrière-plan")
                },
            ]
            if self.tab?.isPrivate == false {
                actions.append(UIAction(title: "Ouvrir en navigation privée", image: UIImage(systemName: "eye.slash")) { _ in
                    BrowserWindows.shared.openPrivateWindow(url: link)
                })
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: actions)] + suggested)
        }
    }

    // MARK: - JavaScript panels

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard mayShowDialog(from: frame) else { return }
        _ = await Dialogs.confirm(title: frame.securityOrigin.host, message: message, cancel: nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard mayShowDialog(from: frame) else { return false }
        return await Dialogs.confirm(title: frame.securityOrigin.host, message: message) ?? false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard mayShowDialog(from: frame) else { return nil }
        return await Dialogs.prompt(title: frame.securityOrigin.host, message: prompt,
                                    fields: [Dialogs.Field(placeholder: "", text: defaultText ?? "")])?.first
    }

    /// "Quitter cette page ?" (beforeunload): closing the tab or leaving the page while it says
    /// something would be lost (WKUIDelegatePrivate; without it WebKit never asks).
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let tab, let browser = tab.browser, BrowserWindows.shared.active === browser else { return completionHandler(true) }
        if browser.selectedTab !== tab {
            // Asked about a tab the user is closing from the list: show it while asking.
            guard tab.closeRequested else { return completionHandler(true) }
            browser.select(tab)
        }
        tab.isAskingToStay = true
        let host = frame.securityOrigin.host
        Task { [weak tab] in
            let leave = await Dialogs.confirm(title: "Quitter cette page ?",
                                              message: (host.isEmpty ? "Cette page" : host) + " indique que les modifications que vous avez faites pourraient ne pas être enregistrées.",
                                              confirm: "Quitter la page", cancel: "Rester") ?? true
            tab?.isAskingToStay = false
            if !leave { tab?.closeRequested = false }
            completionHandler(leave)
        }
    }

    /// Recent dialogs of this tab, to stop a page that opens them in a loop.
    private var recentDialogs: [Date] = []

    /// False — the page gets the answer of a dismissed dialog — when the tab isn't the one shown
    /// or when the page keeps opening dialogs.
    private func mayShowDialog(from frame: WKFrameInfo) -> Bool {
        guard isShown else {
            let host = frame.securityOrigin.host
            tab?.browser?.showToast("exclamationmark.bubble", "\(host.isEmpty ? "Un onglet" : host) a voulu afficher une alerte en arrière-plan")
            return false
        }
        let now = Date()
        recentDialogs = recentDialogs.filter { now.timeIntervalSince($0) < 10 } + [now]
        return recentDialogs.count <= 3
    }

    // File uploads, camera and microphone: WebKit shows the system's own pickers and prompts on iOS.
}
