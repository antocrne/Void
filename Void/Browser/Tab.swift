import AppKit
import WebKit
import Observation

/// Last known media state of one frame of a tab, as reported by media.js.
struct MediaFrameState {
    let frame: WKFrameInfo
    var hasVideo: Bool
    var playing: Bool
    var audible: Bool
    var inPiP: Bool
}

/// A browser tab. The WKWebView is created lazily and can be released ("sleep")
/// while keeping the URL, title and favicon.
@MainActor @Observable
final class Tab: Identifiable {
    let id: UUID
    let isPrivate: Bool

    var title: String
    var url: URL?
    var favicon: NSImage?
    @ObservationIgnored var faviconData: Data?
    var isPinned: Bool

    private(set) var webView: VoidWebView?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var loadError: String?
    /// Every resource of the page came over an encrypted connection (the lock in the address field).
    var hasOnlySecureContent = true

    // Media / Picture in Picture
    var hasVideo = false
    var isPlayingVideo = false
    var isAudible = false {
        didSet { if isAudible != oldValue { ExtensionEvents.tabChanged(self, .audio) } }
    }
    var isInPiP = false
    var isInFloatingPlayer = false
    /// A video (or any element) of the page is fullscreen: WebKit has moved the web view into its
    /// own window and left a placeholder in ours; nothing may move either until it's back.
    var isInElementFullscreen = false
    @ObservationIgnored var autoPiPEngaged = false
    @ObservationIgnored var mediaFrames: [String: MediaFrameState] = [:]

    // Reader mode
    var reader: ReaderArticle? {
        didSet { if (reader == nil) != (oldValue == nil) { ExtensionEvents.tabChanged(self, .readerMode) } }
    }

    // Tab UI / automatic sleep
    /// 0…1, how far the main frame is scrolled (activity.js).
    var readingProgress: Double = 0
    /// The user typed into a field of the current page (activity.js): the tab must stay awake.
    @ObservationIgnored var hasUserInput = false
    /// Created by the page (window.open / target=_blank): keeps its opener link, never auto-slept.
    @ObservationIgnored var openedByPage = false
    /// Back/forward list saved by an automatic sleep, restored at wake-up.
    @ObservationIgnored private var savedInteractionState: Any?
    /// Scroll position read just before an automatic sleep, put back after the wake-up load
    /// (WebKit's saved state can lag behind the last scroll).
    @ObservationIgnored var pendingScroll: CGPoint?

    // Passwords
    var loginAccounts: [String] = []
    @ObservationIgnored var loginHost: String?
    @ObservationIgnored var loginFrame: WKFrameInfo?

    /// Last address written to the history (a page load, or a web app changing its address).
    @ObservationIgnored var lastRecordedURL: URL?
    @ObservationIgnored private var historyWork: DispatchWorkItem?

    /// Closed for good (not asleep): late changes are no longer reported to extensions.
    @ObservationIgnored var isClosed = false
    /// The user asked to close the tab and its page is being asked (BrowserModel.requestClose).
    @ObservationIgnored var closeRequested = false
    /// The page's "Quitter cette page ?" sheet is up.
    @ObservationIgnored var isAskingToStay = false
    @ObservationIgnored weak var space: Space?
    /// The window model owning this tab.
    var browser: BrowserModel? { space?.browser }
    @ObservationIgnored var lastAccess = Date()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: TabWebDelegate?
    @ObservationIgnored private var popupConfiguration: WKWebViewConfiguration?
    @ObservationIgnored private var webViewBeingCreated: VoidWebView?

    init(id: UUID = UUID(), url: URL?, title: String = "", isPinned: Bool = false,
         isPrivate: Bool = false, faviconData: Data? = nil, popupConfiguration: WKWebViewConfiguration? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.isPrivate = isPrivate
        self.faviconData = faviconData
        self.favicon = faviconData.flatMap(NSImage.init(data:))
        self.popupConfiguration = popupConfiguration
        self.openedByPage = popupConfiguration != nil
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        // An extension's page (options…): its name rather than its random address.
        if url?.scheme == "webkit-extension", #available(macOS 15.4, *),
           let name = ExtensionManager.running?.controller.extensionContext(for: url!)?.webExtension.displayName {
            return name
        }
        if let host = url?.host() { return host.voidNormalizedHost }
        return "Nouvel onglet"
    }

    var isAsleep: Bool { webView == nil }

    /// Returns the tab's web view, creating it (and loading `url`) if the tab was asleep.
    @discardableResult
    func ensureWebView() -> VoidWebView {
        if let webView { return webView }
        // Setting `webView` notifies observers *before* the value is stored; SwiftUI can then
        // re-enter here synchronously (PageView.onChange) and must get this same web view.
        if let webViewBeingCreated { return webViewBeingCreated }
        let isPopup = popupConfiguration != nil
        let configuration = popupConfiguration ?? WebViewFactory.configuration(for: space, isPrivate: isPrivate, url: url)
        popupConfiguration = nil

        let wv = WebViewFactory.makeWebView(configuration: configuration)
        wv.tab = self
        let delegate = TabWebDelegate(tab: self)
        self.delegate = delegate
        wv.navigationDelegate = delegate
        wv.uiDelegate = delegate
        observe(wv)
        webViewBeingCreated = wv
        webView = wv
        webViewBeingCreated = nil

        if let state = savedInteractionState {
            // Woken from automatic sleep: same history (and place, see restorePendingScroll).
            savedInteractionState = nil
            ContentRules.shared.whenReady { [weak wv] in wv?.interactionState = state }
        } else if !isPopup, let url {
            ContentRules.shared.whenReady { [weak wv] in wv?.load(URLRequest(url: url)) }
        }
        return wv
    }

    func load(_ url: URL) {
        self.url = url
        loadError = nil
        reader = nil
        let wv = ensureWebView()
        wv.load(URLRequest(url: url))
    }

    /// Releases the web view (pinned tabs on ⌘W, memory). Never while in PiP, unless `force`
    /// (the tab is being closed, or its page is gone): PiP must then already have been exited.
    func sleep(force: Bool = false) {
        // Fullscreen first: WebKit must put the web view back in the window before it's released,
        // or its fullscreen window would stay behind, black.
        if isInElementFullscreen, let webView {
            webView.closeAllMediaPresentations { [weak self] in
                self?.isInElementFullscreen = false
                self?.sleep(force: force)
            }
            return
        }
        if force { isInPiP = false; isInFloatingPlayer = false; autoPiPEngaged = false }
        guard let webView, !isInPiP, !isInFloatingPlayer else { return }
        observations.forEach { $0.invalidate() }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        delegate = nil
        isLoading = false
        progress = 0
        hasVideo = false
        isPlayingVideo = false
        isAudible = false
        mediaFrames = [:]
        reader = nil
        loginAccounts = []
        readingProgress = 0
        hasUserInput = false
        // What described the released page: the next web view reports its own.
        canGoBack = false
        canGoForward = false
        hasOnlySecureContent = true
        isInElementFullscreen = false
        closeRequested = false
        isAskingToStay = false
        historyWork?.cancel()
    }

    /// Automatic sleep: remembers the scroll position, then releases the web view (unless the
    /// tab was shown or became busy in the meantime).
    func sleepKeepingPlace(idleFor interval: TimeInterval) async {
        guard let webView else { return }
        let position = await webView.voidCall("return [window.scrollX, window.scrollY];") as? [Double]
        guard browser?.selectedTab !== self, canAutoSleep(idleFor: interval) else { return }
        if let position, position.count == 2 { pendingScroll = CGPoint(x: position[0], y: position[1]) }
        savedInteractionState = webView.interactionState
        sleep()
    }

    /// The web content process of a tab that isn't shown has crashed: release the web view and
    /// keep its back/forward list, so the page reloads — once — when the tab is shown again.
    func sleepAfterCrash() {
        sleepKeepingHistory()
    }

    /// Releases the web view now, PiP included, keeping its back/forward list for the next wake-up.
    func sleepKeepingHistory() {
        guard let webView else { return }
        savedInteractionState = webView.interactionState
        sleep(force: true)
    }

    /// A navigation committed: the page now shown is the one at `url`.
    func didCommit(_ url: URL?) {
        guard let url, url != self.url else { return }
        self.url = url
        ExtensionEvents.tabChanged(self, .url)
        browser?.setNeedsSave()
    }

    /// A web app changing its address without loading a page (pushState): no didFinish, so the
    /// visit is written here — once the address has stayed a moment, and unless the page load
    /// under way writes it anyway.
    private func recordInHistoryIfStill(_ url: URL) {
        guard !isPrivate, browser?.isEphemeralSession != true else { return }
        historyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let webView = self.webView, !webView.isLoading, webView.url == url,
                  self.lastRecordedURL != url else { return }
            HistoryStore.shared.record(url: url, title: webView.title ?? self.title)
            self.lastRecordedURL = url
        }
        historyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// After waking up: puts the page back where it was if WebKit didn't.
    func restorePendingScroll() {
        guard let point = pendingScroll, let webView else { return }
        pendingScroll = nil
        let script = "if (Math.abs(window.scrollY - y) > 40) window.scrollTo(x, y); return window.scrollY;"
        Task {
            for delay in [0, 600] {   // late layout (images, fonts) can shorten the page at first
                try? await Task.sleep(for: .milliseconds(delay))
                _ = await webView.voidCall(script, arguments: ["x": point.x, "y": point.y])
            }
        }
    }

    /// Automatic sleep (Settings → Onglets): only idle tabs. Pinned tabs are never passed here;
    /// tabs playing sound, in a call (camera/microphone), with typed text, in PiP or reader mode stay awake.
    func canAutoSleep(idleFor interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let webView, !isPinned, !openedByPage, reader == nil else { return false }
        guard now.timeIntervalSince(lastAccess) >= interval else { return false }
        if isAudible || isPlayingVideo || isInPiP || isInFloatingPlayer || isInElementFullscreen || hasUserInput { return false }
        if webView.cameraCaptureState != WKMediaCaptureState.none || webView.microphoneCaptureState != WKMediaCaptureState.none { return false }
        return true
    }

    private func observe(_ wv: WKWebView) {
        observations = [
            wv.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let t = wv.title, !t.isEmpty else { return }
                    self.title = t
                    ExtensionEvents.tabChanged(self, .title)
                    if !self.isPrivate, self.browser?.isEphemeralSession != true, let url = wv.url {
                        HistoryStore.shared.updateTitle(url: url, title: t)
                    }
                }
            },
            wv.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    // WebKit reports the URL of a navigation as soon as it starts. Showing it
                    // before it commits would let a page display "bank.com" (and a lock) over its
                    // own content with a navigation that never completes: only same-origin
                    // changes (pushState, anchors) are taken here, the rest at commit.
                    guard let self, let u = wv.url, u != self.url else { return }
                    guard self.url == nil || u.voidSameOrigin(as: self.url) else { return }
                    self.url = u
                    ExtensionEvents.tabChanged(self, .url)
                    self.browser?.setNeedsSave()
                    self.recordInHistoryIfStill(u)
                }
            },
            wv.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.hasOnlySecureContent = wv.hasOnlySecureContent }
            },
            wv.observe(\.fullscreenState, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    let fullscreen = wv.fullscreenState != .notInFullscreen
                    if self?.isInElementFullscreen != fullscreen { self?.isInElementFullscreen = fullscreen }
                }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = wv.isLoading
                    ExtensionEvents.tabChanged(self, .loading)
                }
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
            },
            wv.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            wv.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
        ]
    }

    func setFavicon(_ image: NSImage, data: Data) {
        favicon = image
        faviconData = data
        browser?.setNeedsSave()
    }
}

extension URL {
    /// Same scheme, host and port.
    func voidSameOrigin(as other: URL?) -> Bool {
        guard let other else { return false }
        return scheme?.lowercased() == other.scheme?.lowercased() && host()?.lowercased() == other.host()?.lowercased()
            && port == other.port
    }
}
