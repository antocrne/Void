import UIKit
import WebKit

/// A tab's web view. The link menu (touch and hold) is built by TabWebDelegate.
final class VoidWebView: WKWebView {
    weak var tab: Tab?
    /// Reported by core.js on a `contextmenu` event (a pointer's secondary click on iPad).
    var contextLinkURL: URL?
    var contextImageURL: URL?
    var contextSelection = ""
}
