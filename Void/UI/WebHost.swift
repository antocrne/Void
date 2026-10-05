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
///
/// Side by side (SplitView.swift): the selected tab and its partner each take one side, at the
/// frames SplitGeometry gives; PageView draws the divider and the overlays at the same places.
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
    /// Side by side: the frames of the selected tab's web view and of its partner's.
    private var split: (activeIsLeft: Bool, ratio: Double)?
    private weak var active: WKWebView?
    private weak var partner: WKWebView?

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

    private struct Desired {
        var active: WKWebView?
        var partner: WKWebView?
        var split: (activeIsLeft: Bool, ratio: Double)?
        var keepAlive: [WKWebView] = []
        var frozen = false
    }

    @MainActor
    private static func desired(for browser: BrowserModel?) -> Desired {
        guard let browser else { return Desired() }
        let tab = browser.selectedTab
        let active = (tab?.isInFloatingPlayer ?? true) ? nil : tab?.webView
        let frozen = browser.allTabs.contains(where: \.isInElementFullscreen)
        var result = Desired(active: active, keepAlive: browser.keepAliveTabs.compactMap(\.webView), frozen: frozen)
        if let shown = browser.shownSplit, let tab {
            let other = shown.left === tab ? shown.right : shown.left
            result.partner = other.isInFloatingPlayer ? nil : other.webView
            result.split = (shown.left === tab, browser.currentSpace.splitRatio)
        }
        return result
    }

    func sync() {
        guard Self.owner(of: browser) === self else { return }
        let wanted = MainActor.assumeIsolated { Self.desired(for: browser) }
        guard !wanted.frozen else { return }
        let active = wanted.active
        split = wanted.split
        self.active = active
        partner = wanted.partner
        let shown = [wanted.partner, active].compactMap { $0 }
        let background = wanted.keepAlive.filter { view in !shown.contains { $0 === view } }
        let desired: [WKWebView] = background + shown

        for sub in subviews where !desired.contains(where: { $0 === sub }) {
            sub.removeFromSuperview()
        }
        for webView in desired where webView.superview !== self {
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
        // The shown views must be on top (the active one last); don't reorder otherwise.
        if let partner = wanted.partner, !subviews.suffix(active == nil ? 1 : 2).contains(where: { $0 === partner }) {
            addSubview(partner, positioned: .above, relativeTo: nil)
        }
        if let active, subviews.last !== active {
            addSubview(active, positioned: .above, relativeTo: nil)
        }
        for webView in desired { webView.frame = frame(for: webView) }

        if active !== currentActive {
            currentActive = active
            if let active, let window, !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(active)
            }
        }
    }

    /// The selected tab's and its partner's sides; everything else (kept alive) lies underneath.
    private func frame(for view: NSView) -> NSRect {
        guard let split else { return bounds }
        let sides = SplitGeometry.sides(in: bounds.size, ratio: split.ratio)
        if view === active { return split.activeIsLeft ? sides.left : sides.right }
        if view === partner { return split.activeIsLeft ? sides.right : sides.left }
        return bounds
    }

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = frame(for: $0) }
    }
}

/// Where the two sides of a split go, shared by WebHost (web views) and PageView (divider, overlays).
enum SplitGeometry {
    static let divider: CGFloat = 8
    static let minSide: CGFloat = 280

    /// Width of the left side for a page area `width` wide.
    static func leftWidth(_ width: CGFloat, ratio: Double) -> CGFloat {
        let available = max(0, width - divider)
        let low = min(minSide, available / 2)
        return min(max(available * ratio, low), available - low).rounded()
    }

    static func sides(in size: CGSize, ratio: Double) -> (left: CGRect, right: CGRect) {
        let left = leftWidth(size.width, ratio: ratio)
        return (CGRect(x: 0, y: 0, width: left, height: size.height),
                CGRect(x: left + divider, y: 0, width: max(0, size.width - left - divider), height: size.height))
    }

    /// The ratio that puts the divider at `leftWidth`.
    static func ratio(leftWidth: CGFloat, in width: CGFloat) -> Double {
        let available = max(1, width - divider)
        return min(0.85, max(0.15, Double(leftWidth / available)))
    }
}
