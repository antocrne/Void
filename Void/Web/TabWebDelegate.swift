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
        if navigationAction.shouldPerformDownload { return .download }
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

        // ⌘-click / middle-click → new tab (⌘⇧ = in the foreground).
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame != nil {
            let flags = navigationAction.modifierFlags
            if flags.contains(.command) || navigationAction.buttonNumber == 2 {
                browser.openTab(url: url, background: !flags.contains(.shift), after: tab)
                return .cancel
            }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType { return .download }
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, from: navigationAction.request.url, in: browser)
        closeIfEmpty(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, from: navigationResponse.response.url, in: browser)
        closeIfEmpty(webView)
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
        tab.readingProgress = 0
        tab.hasUserInput = false
        PiPController.shared.resetFrames(of: tab)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab else { return }
        if !tab.isPrivate, !browser.isEphemeralSession, let url = webView.url {
            HistoryStore.shared.record(url: url, title: webView.title ?? "")
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
        let background = flags.contains(.command) && !flags.contains(.shift)
        let newTab = browser.openTab(url: nil, background: background, after: tab, popupConfiguration: configuration)
        newTab.url = navigationAction.request.url
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

    // MARK: - File upload
    // (Camera/mic: not implementing the permission delegate keeps WebKit's default, which prompts.)

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
