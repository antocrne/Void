import SwiftUI
import UIKit
import WebKit
import Observation

/// Hosts the selected tab's WKWebView (see the Mac's WebHost for the reasoning, the same here).
///
/// Web views of tabs that are playing media (or are in Picture in Picture) are kept attached,
/// stacked underneath the active one: WebKit considers a detached web view "not visible" and may
/// pause its video or end its PiP session.
///
/// Element fullscreen: WebKit moves the web view elsewhere while it lasts; the host doesn't touch
/// its views until fullscreen ends.
///
/// One host per browser holds the web views: the last one to join the window. Going between the
/// iPhone and iPad layouts (Split View, Stage Manager) builds a new page area while the old one
/// goes; both would claim the same web views.
struct WebHost: UIViewRepresentable {
    let browser: BrowserModel

    func makeUIView(context: Context) -> WebHostView { WebHostView(browser: browser) }

    func updateUIView(_ view: WebHostView, context: Context) {
        view.browser = browser
        view.sync()
    }
}

final class WebHostView: UIView {
    /// The browser on screen: the normal one, or private browsing.
    weak var browser: BrowserModel? {
        didSet {
            guard browser !== oldValue else { return }
            generation += 1
            tracking = false
            if window != nil { track() }
        }
    }
    private var tracking = false
    /// Bumped when the browser changes: an observation of the previous one is dropped.
    private var generation = 0

    init(browser: BrowserModel) {
        self.browser = browser
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Every host in a window, oldest first.
    private static var attached: [WeakHost] = []

    private final class WeakHost {
        weak var view: WebHostView?
        init(_ view: WebHostView) { self.view = view }
    }

    /// The host showing `browser`'s pages: the newest one in a window.
    private static func owner(of browser: BrowserModel?) -> WebHostView? {
        guard let browser else { return nil }
        return attached.last { $0.view?.browser === browser && $0.view?.window != nil }?.view
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
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
        let generation = generation
        MainActor.assumeIsolated {
            withObservationTracking {
                _ = Self.desired(for: browser)
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
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
        let frozen = browser.allTabs.contains(where: \.isInElementFullscreen)
        return (browser.selectedTab?.webView, browser.keepAliveTabs.compactMap(\.webView), frozen)
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
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(webView)
        }
        // The active view must be on top (last subview); don't reorder otherwise.
        if let active, subviews.last !== active { bringSubviewToFront(active) }
        for webView in desired { webView.frame = bounds }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.frame = bounds }
    }
}
