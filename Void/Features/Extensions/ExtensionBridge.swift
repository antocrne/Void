import AppKit
import WebKit

/// What extensions are told about Void's tabs and windows (chrome.tabs.onCreated, onActivated…).
/// Called by the model whatever the macOS version; does nothing unless extensions are running.
@MainActor
enum ExtensionEvents {
    struct Change: OptionSet {
        let rawValue: Int
        static let url = Change(rawValue: 1 << 0)
        static let title = Change(rawValue: 1 << 1)
        static let loading = Change(rawValue: 1 << 2)
        static let pinned = Change(rawValue: 1 << 3)
        static let audio = Change(rawValue: 1 << 4)
        static let readerMode = Change(rawValue: 1 << 5)
    }

    static func tabOpened(_ tab: Tab) {
        guard #available(macOS 15.4, *), let bridge = ExtensionManager.running?.bridge else { return }
        bridge.controller.didOpenTab(bridge.tab(tab))
    }

    /// After the tab has left its space.
    static func tabClosed(_ tab: Tab, windowClosing: Bool = false) {
        guard #available(macOS 15.4, *), let bridge = ExtensionManager.running?.bridge else { return }
        bridge.closed(tab, windowClosing: windowClosing)
    }

    static func tabActivated(_ tab: Tab, previous: Tab?) {
        guard tab !== previous, #available(macOS 15.4, *), let bridge = ExtensionManager.running?.bridge else { return }
        bridge.controller.didActivateTab(bridge.tab(tab), previousActiveTab: previous.map(bridge.tab))
    }

    /// `index`: where the tab was in its window before the move (see `BrowserModel.extensionTabs`).
    static func tabMoved(_ tab: Tab, from index: Int) {
        guard #available(macOS 15.4, *), let bridge = ExtensionManager.running?.bridge, let browser = tab.browser else { return }
        guard browser.extensionTabs.firstIndex(where: { $0 === tab }) != index else { return }
        bridge.controller.didMoveTab(bridge.tab(tab), from: index, in: bridge.window(browser))
    }

    static func tabChanged(_ tab: Tab, _ change: Change) {
        guard #available(macOS 15.4, *), let bridge = ExtensionManager.running?.bridge else { return }
        var properties: WKWebExtension.TabChangedProperties = []
        if change.contains(.url) { properties.insert(.URL) }
        if change.contains(.title) { properties.insert(.title) }
        if change.contains(.loading) { properties.insert(.loading) }
        if change.contains(.pinned) { properties.insert(.pinned) }
        if change.contains(.audio) { properties.insert(.playingAudio) }
        if change.contains(.readerMode) { properties.insert(.readerMode) }
        bridge.controller.didChangeTabProperties(properties, for: bridge.tab(tab))
    }

    static func windowOpened(_ browser: BrowserModel) {
        guard #available(macOS 15.4, *), let bridge = ExtensionManager.running?.bridge else { return }
        bridge.controller.didOpenWindow(bridge.window(browser))
    }

    /// Before the window's tabs are torn down.
    static func windowClosing(_ browser: BrowserModel) {
        guard #available(macOS 15.4, *), let bridge = ExtensionManager.running?.bridge else { return }
        for tab in browser.extensionTabs { bridge.closed(tab, windowClosing: true) }
        bridge.controller.didCloseWindow(bridge.window(browser))
        bridge.forget(browser)
    }

    static func windowFocused(_ browser: BrowserModel) {
        guard #available(macOS 15.4, *), let bridge = ExtensionManager.running?.bridge else { return }
        bridge.controller.didFocusWindow(bridge.window(browser))
    }
}

extension BrowserModel {
    /// The window's tabs as extensions see them: every space, pinned tabs first in each.
    var extensionTabs: [Tab] { spaces.flatMap(\.allTabs) }
}

/// Stable stand-ins for Void's tabs and windows (WebKit wants NSObjects, and the same object
/// for the same tab every time).
@available(macOS 15.4, *)
@MainActor
final class ExtensionBridge {
    let controller: WKWebExtensionController
    private var tabs: [ObjectIdentifier: ExtensionTab] = [:]
    private var windows: [ObjectIdentifier: ExtensionWindow] = [:]

    init(controller: WKWebExtensionController) {
        self.controller = controller
    }

    func tab(_ tab: Tab) -> ExtensionTab {
        if let existing = tabs[ObjectIdentifier(tab)], existing.tab === tab { return existing }
        let adapter = ExtensionTab(tab: tab, bridge: self)
        tabs[ObjectIdentifier(tab)] = adapter
        return adapter
    }

    func window(_ browser: BrowserModel) -> ExtensionWindow {
        if let existing = windows[ObjectIdentifier(browser)], existing.browser === browser { return existing }
        let adapter = ExtensionWindow(browser: browser, bridge: self)
        windows[ObjectIdentifier(browser)] = adapter
        return adapter
    }

    /// Windows extensions may see: every browser window, private ones included (WebKit hides
    /// them from extensions without access to private data).
    var openWindows: [ExtensionWindow] {
        BrowserWindows.shared.all.filter { $0.window != nil || $0 === BrowserModel.shared }.map(window)
    }

    func closed(_ tab: Tab, windowClosing: Bool) {
        guard let adapter = tabs.removeValue(forKey: ObjectIdentifier(tab)) else {
            // Never shown to an extension: nothing to tell.
            return
        }
        adapter.isClosed = true
        controller.didCloseTab(adapter, windowIsClosing: windowClosing)
    }

    func forget(_ browser: BrowserModel) {
        windows[ObjectIdentifier(browser)] = nil
    }

    /// Tab for an extension-provided one (it can only be ours).
    static func tab(_ tab: (any WKWebExtensionTab)?) -> Tab? { (tab as? ExtensionTab)?.tab }
    static func browser(_ window: (any WKWebExtensionWindow)?) -> BrowserModel? { (window as? ExtensionWindow)?.browser }
}

private let bridgeError = NSError(domain: "app.void.extensions", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Onglet ou fenêtre introuvable"])

@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    private unowned let bridge: ExtensionBridge
    /// Set once extensions have been told the tab closed: late calls get nothing.
    var isClosed = false

    init(tab: Tab, bridge: ExtensionBridge) {
        self.tab = tab
        self.bridge = bridge
    }

    private var live: Tab? { isClosed ? nil : tab }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        live?.browser.map(bridge.window)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab = live, let browser = tab.browser else { return NSNotFound }
        return browser.extensionTabs.firstIndex { $0 === tab } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { live?.webView }
    func title(for context: WKWebExtensionContext) -> String? { live?.displayTitle }
    func url(for context: WKWebExtensionContext) -> URL? { live?.url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { live?.isPinned ?? false }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { live?.isAudible ?? false }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(live?.isLoading ?? false) }
    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { live?.webView != nil }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { live?.reader != nil }
    func isMuted(for context: WKWebExtensionContext) -> Bool { live?.webView.map(WebKitSPI.isPageMuted) ?? false }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab = live else { return false }
        return tab.space?.selectedTabID == tab.id && tab.space?.id == tab.browser?.currentSpaceID
    }

    func size(for context: WKWebExtensionContext) -> CGSize { live?.webView?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(live?.webView?.pageZoom ?? 1) }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        live?.webView?.pageZoom = min(3, max(0.5, zoomFactor))
        completionHandler(nil)
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab = live, let browser = tab.browser else { return completionHandler(bridgeError) }
        if tab.isPinned != pinned { browser.togglePin(tab) }
        completionHandler(nil)
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView = live?.webView else { return completionHandler(nil) }
        WebKitSPI.setPageMuted(webView, muted)
        completionHandler(nil)
    }

    func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab = live, let browser = tab.browser else { return completionHandler(bridgeError) }
        if (tab.reader != nil) != active {
            if browser.selectedTab !== tab { browser.select(tab) }
            browser.toggleReader()
        }
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab = live else { return completionHandler(bridgeError) }
        tab.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView = live?.ensureWebView() else { return completionHandler(bridgeError) }
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        live?.webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        live?.webView?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab = live, let browser = tab.browser else { return completionHandler(bridgeError) }
        browser.select(tab)
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        // One selected tab per window in Void: selecting is activating, deselecting does nothing.
        guard selected else { return completionHandler(nil) }
        activate(for: context, completionHandler: completionHandler)
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard let tab = live, let browser = tab.browser else { return completionHandler(nil, bridgeError) }
        let copy = browser.openTab(url: tab.url, in: tab.space, background: !configuration.shouldBeActive, after: tab)
        completionHandler(bridge.tab(copy), nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab = live, let browser = tab.browser else { return completionHandler(bridgeError) }
        browser.close(tab, force: true)
        completionHandler(nil)
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext,
                      completionHandler: @escaping (NSImage?, Error?) -> Void) {
        guard let webView = live?.webView else { return completionHandler(nil, bridgeError) }
        webView.takeSnapshot(with: configuration) { image, error in completionHandler(image, error) }
    }

    func detectWebpageLocale(for context: WKWebExtensionContext, completionHandler: @escaping (Locale?, Error?) -> Void) {
        guard let webView = live?.webView else { return completionHandler(nil, nil) }
        Task { @MainActor in
            let lang = await webView.voidCall("return document.documentElement.lang || navigator.language;") as? String
            completionHandler(lang.map(Locale.init(identifier:)), nil)
        }
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var browser: BrowserModel?
    private unowned let bridge: ExtensionBridge

    init(browser: BrowserModel, bridge: ExtensionBridge) {
        self.browser = browser
        self.bridge = bridge
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        (browser?.extensionTabs ?? []).map(bridge.tab)
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        browser?.selectedTab.map(bridge.tab)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { browser?.isPrivate ?? false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = browser?.window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = browser?.window else { return completionHandler(bridgeError) }
        switch state {
        case .minimized: window.miniaturize(nil)
        case .maximized: if !window.isZoomed { window.zoom(nil) }
        case .fullscreen: if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        default:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
        completionHandler(nil)
    }

    /// Extensions use top-left screen coordinates, AppKit bottom-left ones.
    func frame(for context: WKWebExtensionContext) -> CGRect {
        guard let window = browser?.window else { return .null }
        return Self.flip(window.frame)
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        guard let screen = browser?.window?.screen ?? NSScreen.main else { return .null }
        return Self.flip(screen.frame)
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = browser?.window else { return completionHandler(bridgeError) }
        // Unspecified fields are NaN: keep the current ones.
        let current = Self.flip(window.frame)
        let target = CGRect(x: frame.origin.x.isNaN ? current.minX : frame.origin.x,
                            y: frame.origin.y.isNaN ? current.minY : frame.origin.y,
                            width: frame.width.isNaN ? current.width : frame.width,
                            height: frame.height.isNaN ? current.height : frame.height)
        window.setFrame(Self.flip(target), display: true, animate: false)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = browser?.window else { return completionHandler(bridgeError) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = browser?.window else { return completionHandler(bridgeError) }
        window.performClose(nil)
        completionHandler(nil)
    }

    private static func flip(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
