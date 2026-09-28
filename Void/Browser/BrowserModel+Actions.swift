import AppKit
import SwiftUI
import WebKit

/// Actions shared by menus, keyboard shortcuts and chrome buttons.
extension BrowserModel {
    private var webView: VoidWebView? { selectedTab?.webView }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reload(fromOrigin: Bool = false) {
        guard let tab = selectedTab else { return }
        tab.loadError = nil
        guard let webView = tab.webView else { tab.ensureWebView(); return }
        if webView.url == nil, let url = tab.url { webView.load(URLRequest(url: url)); return }
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
    }

    func stopLoading() { webView?.stopLoading() }

    func zoom(_ delta: CGFloat?) {
        guard let webView else { return }
        webView.pageZoom = delta.map { min(3, max(0.5, webView.pageZoom + $0)) } ?? 1
    }

    func toggleBookmark() {
        guard let tab = selectedTab, let url = tab.url else { return }
        let added = BookmarkStore.shared.toggle(url: url, title: tab.title)
        showToast(added ? "star.fill" : "star.slash", added ? "Ajouté aux favoris" : "Retiré des favoris")
    }

    func toggleReader() {
        guard let tab = selectedTab else { return }
        ReaderMode.toggle(tab)
    }

    func togglePiP() {
        guard let tab = selectedTab else { return }
        Task { await PiPController.shared.toggle(tab) }
    }

    func hideElement() {
        guard let tab = selectedTab else { return }
        ElementHider.shared.startPicking(in: tab)
    }

    func showInspector(console: Bool) {
        guard let webView else { return }
        WebKitSPI.showInspector(webView, console: console)
    }

    func toggleFind() {
        guard selectedTab?.webView != nil else { return }
        withAnimation(Theme.quick) { findBarVisible.toggle() }
    }

    func find(_ text: String, backwards: Bool = false) {
        guard let webView, !text.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            if !result.matchFound { self?.showToast("magnifyingglass", "Aucun résultat pour « \(text) »") }
        }
    }

    func print() {
        guard let webView, let window = webView.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func copyURL() {
        guard let url = selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast("link", "Lien copié")
    }

    func toggleAdBlockForCurrentSite() {
        guard let host = selectedTab?.url?.host() else { return }
        AppSettings.shared.toggleAdBlock(for: host)
        let active = AppSettings.shared.isAdBlockActive(on: host)
        showToast(active ? "shield.lefthalf.filled" : "shield.slash", active ? "Bloqueur activé sur \(host.voidNormalizedHost)" : "Bloqueur désactivé sur \(host.voidNormalizedHost)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.reload() }
    }

    func showLibrary(_ section: LibrarySection) {
        BrowserModel.shared.librarySection = section
        (openWindowAction ?? BrowserModel.shared.openWindowAction)?(WindowID.library)
    }

    func toggleSidebar() {
        let settings = AppSettings.shared
        withAnimation(Theme.spring) {
            if settings.sidebarAutoHide {
                // Leaving "hidden until the edge" docks the sidebar again.
                settings.sidebarAutoHide = false
                settings.sidebarVisible = true
            } else {
                settings.sidebarVisible.toggle()
            }
        }
    }

    /// ⌘S: keeps the tabs hidden (the page fills the window; pushing against the left edge
    /// reveals them), or docks them again.
    func toggleTabsHidden() {
        let settings = AppSettings.shared
        guard settings.tabLayout == .sidebar else { return }
        withAnimation(Theme.spring) {
            settings.sidebarAutoHide.toggle()
            if settings.sidebarAutoHide { settings.sidebarVisible = true }
        }
    }

    /// Closes the key window when it isn't the browser window (⌘W in Settings/Library).
    func closeTabOrWindow() {
        if let key = NSApp.keyWindow, key !== window {
            key.performClose(nil)
        } else if selectedTab != nil {
            closeCurrentTab()
        } else {
            window?.performClose(nil)
        }
    }
}
