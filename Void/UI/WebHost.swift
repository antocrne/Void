import AppKit
import SwiftUI
import WebKit
import Observation

/// Hosts the selected tab's WKWebView.
///
/// PiP / background playback: web views of tabs that are playing media (or are in PiP) are
/// *kept attached* to the window, stacked underneath the active one, instead of being
/// removed. WebKit considers a detached or hidden web view "not visible" and may pause
/// its video or tear down the PiP session; a covered-but-attached view stays visible to
/// WebKit, so playback continues and PiP stays alive.
///
/// The host observes BrowserModel itself (Observation) instead of relying only on
/// SwiftUI calling updateNSView, which could be skipped during animated transitions and
/// leave the selected tab's web view out of the window.
///
/// Element fullscreen (a video's fullscreen button): WebKit moves the web view into its own
/// window and puts a placeholder in its place, which it swaps back on exit. Re-adding the web
/// view here meanwhile (e.g. the video starts playing, so keep-alive tabs change) would pull it
/// out of the fullscreen window, which turns black, and removing the placeholder would leave the
/// page blank afterwards: the host doesn't touch its views until fullscreen ends.
///
/// One host per window holds the web views: the last one to join the window. Moving the tabs
/// between the sidebar and the top builds a new page area while the old one fades out; both
/// would claim the same web views, and the old one could keep them as it goes (a blank page).
struct WebHost: NSViewRepresentable {
    let browser: BrowserModel

    func makeNSView(context: Context) -> WebHostView { WebHostView(browser: browser) }
    func updateNSView(_ view: WebHostView, context: Context) { view.sync() }
}

final class WebHostView: NSView {
    /// The window's model (each browser window has its own).
    private weak var browser: BrowserModel?
    private weak var currentActive: WKWebView?
    private var tracking = false

    init(browser: BrowserModel) {
        self.browser = browser
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Every host in a window, oldest first.
    private static var attached: [WeakHost] = []

    private final class WeakHost {
        weak var view: WebHostView?
        init(_ view: WebHostView) { self.view = view }
    }

    /// The host showing `browser`'s pages: the newest one in its window.
    private static func owner(of browser: BrowserModel?) -> WebHostView? {
        guard let browser else { return nil }
        return attached.last { $0.view?.browser === browser && $0.view?.window != nil }?.view
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.attached.removeAll { $0.view == nil || $0.view === self }
        guard window != nil else {
            // Leaving: the host still in the window takes the web views back.
            Self.owner(of: browser)?.sync()
            return
        }
        Self.attached.append(WeakHost(self))
        sync()
        track()
    }

    /// Re-syncs whenever anything the host depends on changes.
    private func track() {
        guard !tracking else { return }
        tracking = true
        MainActor.assumeIsolated {
            withObservationTracking {
                _ = Self.desired(for: browser)
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.tracking = false
                    self.sync()
                    if self.window != nil { self.track() }
                }
            }
        }
    }

    @MainActor
    private static func desired(for browser: BrowserModel?) -> (active: WKWebView?, keepAlive: [WKWebView], frozen: Bool) {
        guard let browser else { return (nil, [], false) }
        let tab = browser.selectedTab
        let active = (tab?.isInFloatingPlayer ?? true) ? nil : tab?.webView
        let frozen = browser.allTabs.contains(where: \.isInElementFullscreen)
        return (active, browser.keepAliveTabs.compactMap(\.webView), frozen)
    }

    func sync() {
        guard Self.owner(of: browser) === self else { return }
        let (active, keepAlive, frozen) = MainActor.assumeIsolated { Self.desired(for: browser) }
        guard !frozen else { return }
        let background = keepAlive.filter { $0 !== active }
        let desired: [WKWebView] = background + (active.map { [$0] } ?? [])

        for sub in subviews where !desired.contains(where: { $0 === sub }) {
            sub.removeFromSuperview()
        }
        for webView in desired where webView.superview !== self {
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
        // The active view must be on top (last subview); don't reorder otherwise.
        if let active, subviews.last !== active {
            addSubview(active, positioned: .above, relativeTo: nil)
        }
        for webView in desired { webView.frame = bounds }

        if active !== currentActive {
            currentActive = active
            if let active, let window, !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(active)
            }
        }
    }

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }
}
