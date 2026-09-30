import WebKit

/// Thin, guarded wrappers around WebKit internals that have no public equivalent on macOS.
/// Every call checks `responds(to:)` first, so a future WebKit that removes one simply
/// makes the feature degrade instead of crashing.
enum WebKitSPI {
    /// Sets a WKPreferences flag through KVC (resolves to `_set<Key>:`).
    static func setPreference(_ prefs: WKPreferences, _ key: String, _ value: Bool) {
        let setter = "_set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard prefs.responds(to: NSSelectorFromString(setter)) else { return }
        prefs.setValue(value, forKey: key)
    }

    // MARK: Picture in Picture (the mechanism Safari uses for its own PiP menu)

    static func canTogglePictureInPicture(_ webView: WKWebView) -> Bool {
        boolValue(webView, "_canTogglePictureInPicture")
    }

    static func isPictureInPictureActive(_ webView: WKWebView) -> Bool {
        boolValue(webView, "_isPictureInPictureActive")
    }

    static func togglePictureInPicture(_ webView: WKWebView) {
        let sel = NSSelectorFromString("_togglePictureInPicture")
        guard webView.responds(to: sel) else { return }
        webView.perform(sel)
    }

    // MARK: Web Inspector

    static func showInspector(_ webView: WKWebView, console: Bool) {
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter),
              let inspector = webView.perform(getter)?.takeUnretainedValue() as? NSObject else { return }
        let action = NSSelectorFromString(console ? "showConsole" : "show")
        if inspector.responds(to: action) { inspector.perform(action) }
    }

    // MARK: Closing

    /// Asks the page to close, running its beforeunload handlers: WebKit then calls
    /// `webViewDidClose` if it may go. Returns true when it is closed at once (no web process),
    /// nil when WebKit has no such method.
    static func tryClose(_ webView: WKWebView) -> Bool? {
        let sel = NSSelectorFromString("_tryClose")
        guard webView.responds(to: sel) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(webView.method(for: sel), to: Call.self)(webView, sel)
    }

    // MARK: Muting (chrome.tabs.update({muted}))

    /// `_WKMediaAudioMuted`, the first bit of WebKit's muted state.
    static func isPageMuted(_ webView: WKWebView) -> Bool {
        let sel = NSSelectorFromString("_mediaMutedState")
        guard webView.responds(to: sel) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(webView.method(for: sel), to: Getter.self)(webView, sel) & 1 != 0
    }

    static func setPageMuted(_ webView: WKWebView, _ muted: Bool) {
        let sel = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: sel), to: Setter.self)(webView, sel, muted ? 1 : 0)
    }

    // MARK: Extensions

    /// The page WebKit hosts an extension's background in (for a service worker, the page that
    /// registers it).
    @available(macOS 15.4, *)
    static func backgroundWebView(_ context: WKWebExtensionContext) -> WKWebView? {
        let sel = NSSelectorFromString("_backgroundWebView")
        guard context.responds(to: sel) else { return nil }
        return context.perform(sel)?.takeUnretainedValue() as? WKWebView
    }

    // MARK: Extension popups

    /// A popup's web view is laid out at its content's own size (up to 800 × 600): off, it is laid
    /// out at the size it is given, like a window. Returns false when WebKit has no such switch.
    @discardableResult
    static func disableSizeToContent(_ webView: WKWebView) -> Bool {
        let sel = NSSelectorFromString("_setSizeToContentAutoSizeMaximumSize:")
        guard webView.responds(to: sel) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, CGSize) -> Void
        unsafeBitCast(webView.method(for: sel), to: Setter.self)(webView, sel, .zero)
        return true
    }

    private static func boolValue(_ object: NSObject, _ name: String) -> Bool {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let imp = object.method(for: sel)
        return unsafeBitCast(imp, to: Getter.self)(object, sel)
    }
}
