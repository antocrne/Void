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

    func sendPageToNotes() {
        guard let tab = selectedTab else { return }
        VoidNotes.shared.sendPage(from: tab)
    }

    #if os(macOS)
    func showInspector(console: Bool) {
        guard let webView else { return }
        WebKitSPI.showInspector(webView, console: console)
    }
    #endif

    func toggleFind() {
        #if os(macOS)
        guard selectedTab?.webView != nil else { return }
        withAnimation(Theme.quick) { findBarVisible.toggle() }
        #else
        // The system's find bar, above the keyboard.
        guard let webView else { return }
        webView.isFindInteractionEnabled = true
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
        #endif
    }

    /// ⌘G / ⌘⇧G: the last search of this window, even with the find bar closed (as in Safari).
    func findNext(backwards: Bool) {
        if lastFindText.isEmpty { toggleFind() } else { find(lastFindText, backwards: backwards) }
    }

    func find(_ text: String, backwards: Bool = false) {
        guard let webView, !text.isEmpty else { return }
        lastFindText = text
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            if !result.matchFound { self?.showToast("magnifyingglass", "Aucun résultat pour « \(text) »") }
        }
    }

    func print() {
        #if os(macOS)
        guard let webView, let window = webView.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        #else
        guard let webView else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = selectedTab?.displayTitle ?? "Void"
        controller.printInfo = info
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true)
        #endif
    }

    func copyURL() {
        guard let url = selectedTab?.url else { return }
        Clipboard.copy(url.absoluteString)
        showToast("link", "Lien copié")
    }

    func toggleAdBlockForCurrentSite() {
        guard let host = selectedTab?.url?.host() else { return }
        AppSettings.shared.toggleAdBlock(for: host)
        let active = AppSettings.shared.isAdBlockActive(on: host)
        showToast(active ? "shield.lefthalf.filled" : "shield.slash", active ? "Bloqueur activé sur \(host.voidNormalizedHost)" : "Bloqueur désactivé sur \(host.voidNormalizedHost)")
        // The page comes back once the new rules are in, and it's this page even if another tab
        // was selected meanwhile.
        let tab = selectedTab
        Task {
            await ContentRules.shared.reloadNow()
            tab?.loadError = nil
            tab?.webView?.reload()
        }
    }

    func showLibrary(_ section: LibrarySection) {
        BrowserModel.shared.librarySection = section
        (openWindowAction ?? BrowserModel.shared.openWindowAction)?(WindowID.library)
    }

    /// The popover next to the downloads button, or the Library window when no button is on screen.
    func showDownloads() {
        if downloadsButtonsShown > 0 { showingDownloads.toggle() } else { showLibrary(.downloads) }
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

    /// Fichier → Nouveau dossier (⌃⌘N): an empty folder in the current space. Its name is typed in
    /// the sidebar, which comes back if it was hidden (or slides out while kept hidden, see
    /// EdgeRevealSidebar).
    func newFolder() {
        guard managesSpaces else { return }
        let settings = AppSettings.shared
        if settings.tabLayout == .sidebar && !settings.sidebarVisible {
            withAnimation(Theme.spring) { settings.sidebarVisible = true }
        }
        addFolder(in: currentSpace)
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

    /// The tabs of `tab`'s space that `closeOtherTabs` would close (pinned tabs stay).
    func otherTabs(than tab: Tab) -> [Tab] { tab.space?.tabs.filter { $0 !== tab } ?? [] }

    /// "Fermer les autres onglets": only `tab` stays, shown, with the space's pinned tabs. The
    /// closed ones can be reopened one by one (⌘⇧T).
    func closeOtherTabs(than tab: Tab) {
        let others = otherTabs(than: tab)
        guard !others.isEmpty else { return }
        select(tab)
        others.forEach { close($0, force: true) }
        #if os(macOS)
        showToast("xmark.square", others.count == 1 ? "1 onglet fermé · ⌘⇧T pour en rouvrir"
                                                    : "\(others.count) onglets fermés · ⌘⇧T pour en rouvrir")
        #else
        showToast("xmark.square", others.count == 1 ? "1 onglet fermé" : "\(others.count) onglets fermés")
        #endif
    }

    #if os(macOS)
    /// Closes the key window when it isn't the browser window (⌘W in Settings/Library).
    func closeTabOrWindow() {
        if let key = NSApp.keyWindow, key !== window {
            key.performClose(nil)
        } else if leaveNewTabPage() {
            // The new tab is dropped: back to the tab it was opened over.
        } else if selectedTab != nil {
            closeCurrentTab()
        } else {
            window?.performClose(nil)
        }
    }
    #endif
}
