import AppKit
import WebKit
import UniformTypeIdentifiers

/// Navigation + UI delegate of one tab's web view.
@MainActor
final class TabWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var tab: Tab?
    /// The window owning the tab (private windows keep links and pop-ups private).
    private var browser: BrowserModel { tab?.browser ?? .shared }

    init(tab: Tab) { self.tab = tab }

    /// webkit-extension: extensions' own pages (WebKit decides which pages may open them).
    private static let internalSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "view-source", "webkit-extension"]

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload {
            return await mayDownload(navigationAction.request.url, in: webView) ? .download : .cancel
        }
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""

        if !Self.internalSchemes.contains(scheme) {
            // mailto:, tel:, zoommtg:, … → hand over to macOS, only on a user click in the page
            // itself, and after asking for anything but the usual system apps.
            let policy = ExternalURLPolicy.decide(scheme: scheme, userClick: navigationAction.navigationType == .linkActivated,
                                                  fromMainFrame: navigationAction.sourceFrame.isMainFrame)
            switch policy {
            case .open: NSWorkspace.shared.open(url)
            case .ask: ExternalURLPolicy.confirmAndOpen(url, from: navigationAction.sourceFrame.securityOrigin.host, in: webView.window)
            case .refuse: break
            }
            return .cancel
        }

        // ⌘-click / middle-click → new tab (⌘⇧ = in the foreground). Only a click made in this very
        // page: the first load of a tab opened by WebKit (the context menu's "Ouvrir le lien dans un
        // nouvel onglet", a target=_blank link) comes with the click that opened it, and sending it
        // to yet another tab would leave this one empty.
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame != nil,
           navigationAction.sourceFrame.webView === webView {
            let flags = navigationAction.modifierFlags
            if flags.contains(.command) || navigationAction.buttonNumber == Self.middleButton {
                browser.openTab(url: url, background: !flags.contains(.shift), after: tab)
                return .cancel
            }
        }
        return .allow
    }

    /// `WKNavigationAction.buttonNumber` is a mask: 1 the left button, 2 the right one, 4 the middle one.
    private static let middleButton = 4

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

    /// Asked once per site (DownloadPermission). The site is the page's; a tab opened just for the
    /// file has none yet, then it's the file's. A refused download leaves no empty tab behind.
    private func mayDownload(_ url: URL?, file: String? = nil, in webView: WKWebView) async -> Bool {
        // A tab opened for the file has no page yet: the site is the one that opened it.
        let opener = webView.backForwardList.currentItem == nil ? tab?.openerHost : nil
        let host = (opener ?? webView.url?.host() ?? url?.host() ?? "").voidNormalizedHost
        let file = file ?? url?.lastPathComponent
        let allowed = await DownloadPermission.request(host, file: file, in: browser, window: webView.window)
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

    /// "Download Linked File / Image / Video" from the context menu: WebKit starts the download
    /// itself and hands it over here (WKUIDelegatePrivate). Without this method the download
    /// gets no delegate and nothing happens.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreate download: WKDownload) {
        DownloadManager.shared.adopt(download, from: download.originalRequest?.url, in: browser)
    }

    /// A link opened in a new tab that turned out to be a download leaves an empty tab behind.
    func closeIfEmpty(_ webView: WKWebView) {
        // Never a pinned tab: it is kept on purpose, even if its address now serves a file.
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
        // Cancelled / interrupted by policy (downloads, ⌘-click) are not errors.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        tab?.loadError = ns.localizedDescription
    }

    // MARK: - HTTP authentication

    /// Methods for which the user types a name and a password. Kerberos (Negotiate) and client
    /// certificates stay with WebKit's default handling.
    private static let passwordMethods: Set<String> = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                                                      NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodDefault]

    /// Sites behind HTTP authentication (routers, NAS, intranets): without this, WebKit never asks
    /// and shows the server's 401 page.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        // Refused three times: the server's own error page.
        guard Self.passwordMethods.contains(space.authenticationMethod), challenge.previousFailureCount < 3 else {
            return (.performDefaultHandling, nil)
        }
        // Only over the tab being shown (like JS dialogs); a hidden tab gets the 401 page, which a reload asks again.
        guard let tab, tab.browser?.selectedTab === tab, let window = webView.window else {
            return (.performDefaultHandling, nil)
        }
        let port = [80, 443].contains(space.port) ? "" : ":\(space.port)"
        let alert = NSAlert()
        alert.messageText = "Connexion à \(space.host)\(port)"
        var info = space.realm.map { "« \($0) » demande un nom d'utilisateur et un mot de passe." }
            ?? "Ce site demande un nom d'utilisateur et un mot de passe."
        if challenge.previousFailureCount > 0 { info = "Nom d'utilisateur ou mot de passe incorrect. " + info }
        if !space.receivesCredentialSecurely { info += "\n\nLa connexion n'est pas chiffrée : le mot de passe sera envoyé en clair." }
        alert.informativeText = info
        let user = NSTextField(string: challenge.proposedCredential?.user ?? "")
        user.placeholderString = "Nom d'utilisateur"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "Mot de passe"
        let fields = NSStackView(views: [user, password])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        for field in [user, password] { field.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        alert.accessoryView = fields
        alert.addButton(withTitle: "Se connecter")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
    }

    /// Last automatic reload after a crash of the page's process (at most one per 30 s).
    private var lastCrashReload: Date?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab else { return }
        // Not shown: no reload now (after memory pressure, every tab reloading at once would
        // make it worse). It comes back when selected.
        guard tab.browser?.selectedTab === tab else { tab.sleepAfterCrash(); return }
        if let last = lastCrashReload, Date().timeIntervalSince(last) < 30 {
            // Crashed again right away: stop here instead of looping.
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
        let flags = navigationAction.modifierFlags
        // ⌘-click or middle click on a target=_blank link: behind, like any other link.
        let background = (flags.contains(.command) || navigationAction.buttonNumber == Self.middleButton) && !flags.contains(.shift)
        let newTab = browser.openTab(url: nil, background: background, after: tab, popupConfiguration: configuration)
        newTab.url = navigationAction.request.url
        newTab.openerHost = webView.url?.host()
        return newTab.ensureWebView()
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab { browser.close(tab, force: true) }
    }

    // MARK: - JavaScript panels

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        return await present(alert, in: webView) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        return await present(alert, in: webView) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// "Quitter cette page ?" (beforeunload): leaving it, reloading it or closing its tab while the
    /// page says something would be lost (WKUIDelegatePrivate; without it WebKit never asks).
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let tab, let browser = tab.browser, let window = webView.window else { return completionHandler(true) }
        if browser.selectedTab !== tab {
            // Asked about a tab the user is closing from the list: show it while asking.
            guard tab.closeRequested else { return completionHandler(true) }
            browser.select(tab)
        }
        tab.isAskingToStay = true
        let alert = NSAlert()
        alert.messageText = "Quitter cette page ?"
        let host = frame.securityOrigin.host
        alert.informativeText = (host.isEmpty ? "Cette page" : host) + " indique que les modifications que vous avez faites pourraient ne pas être enregistrées."
        alert.addButton(withTitle: "Quitter la page")
        alert.addButton(withTitle: "Rester")
        alert.beginSheetModal(for: window) { [weak tab] response in
            let leave = response == .alertFirstButtonReturn
            tab?.isAskingToStay = false
            if !leave { tab?.closeRequested = false }
            completionHandler(leave)
        }
    }

    /// Recent dialogs of this tab, to stop a page that opens them in a loop.
    private var recentDialogs: [Date] = []

    /// Shows a JavaScript dialog as a sheet over the tab. Returns nil — the page gets the answer
    /// of a dismissed dialog — when the tab isn't the one shown (an app-wide modal window from an
    /// invisible tab would block all of Void) or when the page keeps opening dialogs.
    private func present(_ alert: NSAlert, in webView: WKWebView) async -> NSApplication.ModalResponse? {
        guard let tab, tab.browser?.selectedTab === tab, let window = webView.window else {
            let host = alert.messageText.isEmpty ? "Un onglet" : alert.messageText
            tab?.browser?.showToast("exclamationmark.bubble", "\(host) a voulu afficher une alerte en arrière-plan")
            return nil
        }
        let now = Date()
        recentDialogs = recentDialogs.filter { now.timeIntervalSince($0) < 10 } + [now]
        guard recentDialogs.count <= 3 else { return nil }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Camera, microphone, screen

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let tab, tab.browser?.selectedTab === tab, let window = webView.window ?? browser.window else { return .deny }
        let host = origin.host.voidNormalizedHost
        return await MediaPermission.decide(host: host, type: type, in: browser) {
            let alert = NSAlert()
            alert.messageText = "Autoriser « \(host) » à utiliser \(MediaPermission.devices(type)) ?"
            alert.informativeText = "Jusqu'à ce que vous quittiez Void" + (self.browser.isPrivate ? " ou fermiez cette fenêtre privée." : ".")
            alert.addButton(withTitle: "Autoriser")
            alert.addButton(withTitle: "Refuser")
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
    }

    /// Screen sharing (getDisplayMedia) in a video call (WKUIDelegatePrivate). The answer opens the
    /// system's picker of screens and windows (1); 0 refuses.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func webView(_ webView: WKWebView, requestDisplayCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 withSystemAudio: Bool, decisionHandler: @escaping (Int) -> Void) {
        guard let tab, tab.browser?.selectedTab === tab, let window = webView.window ?? browser.window else { return decisionHandler(0) }
        let alert = NSAlert()
        alert.messageText = "Partager votre écran avec « \(origin.host.voidNormalizedHost) » ?"
        alert.informativeText = "macOS vous laissera ensuite choisir l'écran ou la fenêtre à montrer."
        alert.addButton(withTitle: "Choisir quoi partager…")
        alert.addButton(withTitle: "Refuser")
        alert.beginSheetModal(for: window) { decisionHandler($0 == .alertFirstButtonReturn ? 1 : 0) }
    }

    // MARK: - File upload

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else { return panel.runModal() == .OK ? panel.urls : nil }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }
}
