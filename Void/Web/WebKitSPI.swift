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

    private static func boolValue(_ object: NSObject, _ name: String) -> Bool {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let imp = object.method(for: sel)
        return unsafeBitCast(imp, to: Getter.self)(object, sel)
    }
}
