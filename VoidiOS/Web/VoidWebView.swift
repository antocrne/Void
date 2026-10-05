import UIKit
import WebKit

/// A tab's web view. The link menu (touch and hold) is built by TabWebDelegate.
final class VoidWebView: WKWebView {
    weak var tab: Tab?
    /// Reported by core.js on a `contextmenu` event (a pointer's secondary click on iPad).
    var contextLinkURL: URL?
    var contextImageURL: URL?
    var contextSelection = ""
    private var scrollObservations: [NSKeyValueObservation] = []

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // Reading progress straight from the scroll view, at every frame: the page's own reports
        // (activity.js, 10 a second at most) made the address field's fill move in jumps.
        scrollObservations = [
            scrollView.observe(\.contentOffset) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateReadingProgress() } },
            scrollView.observe(\.contentSize) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateReadingProgress() } },
        ]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func updateReadingProgress() {
        guard let tab else { return }
        let scroll = scrollView
        let top = -scroll.adjustedContentInset.top
        let range = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height - top
        let value = range > 40 ? min(1, max(0, (scroll.contentOffset.y - top) / range)) : 0
        if abs(value - tab.readingProgress) >= 0.001 || (value != tab.readingProgress && (value == 0 || value == 1)) {
            tab.readingProgress = value
        }
    }
}
