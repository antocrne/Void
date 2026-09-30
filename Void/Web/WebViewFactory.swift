import AppKit
import WebKit

/// Builds web view configurations. One shared WKUserContentController holds Void's
/// scripts, message handlers and content rule lists for every tab.
@MainActor
enum WebViewFactory {
    /// Isolated JavaScript world: pages can't see or tamper with Void's scripts.
    static let world = WKContentWorld.world(name: "Void")

    static let contentController: WKUserContentController = {
        let ucc = WKUserContentController()
        let router = ScriptMessageRouter.shared
        for name in ScriptMessageRouter.names {
            ucc.add(router, contentWorld: world, name: name)
        }
        ucc.addUserScript(WKUserScript(source: Scripts.core, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        ucc.addUserScript(WKUserScript(source: Scripts.media, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        ucc.addUserScript(WKUserScript(source: Scripts.autofill, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        ucc.addUserScript(WKUserScript(source: Scripts.formfill, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        ucc.addUserScript(WKUserScript(source: Scripts.activity, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        if #available(macOS 15.4, *) {
            // "Ajouter à Void" on the Chrome Web Store's extension pages.
            ucc.addUserScript(WKUserScript(source: Scripts.webstore, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        }
        return ucc
    }()

    /// "Version/x Safari/605.1.15": without it many sites (video players, Google) serve a degraded page.
    static let userAgentSuffix: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(safari ?? "18.0") Safari/605.1.15"
    }()

    /// `url`: the page the web view will show first — an extension's page gets the extension's configuration.
    static func configuration(for space: Space?, isPrivate: Bool, url: URL? = nil) -> WKWebViewConfiguration {
        if #available(macOS 15.4, *), let extensionPage = ExtensionManager.running?.configuration(for: url) {
            return extensionPage
        }
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        // Normal windows: the space's persistent store. Private windows: their space's in-memory
        // store, shared by all the window's tabs and gone when the window closes.
        if let space {
            config.websiteDataStore = space.dataStore
        } else {
            config.websiteDataStore = isPrivate ? .nonPersistent() : BrowserModel.shared.currentSpace.dataStore
        }
        config.applicationNameForUserAgent = userAgentSuffix
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = AppSettings.shared.blockAutoplayWithSound ? .audio : []
        config.defaultWebpagePreferences.preferredContentMode = .desktop

        let prefs = config.preferences
        prefs.isElementFullscreenEnabled = true
        prefs.isFraudulentWebsiteWarningEnabled = true
        // PiP: on macOS there is no public switch (allowsPictureInPictureMediaPlayback is iOS-only).
        // WebKit's internal preference defaults to YES; set it explicitly when available.
        WebKitSPI.setPreference(prefs, "allowsPictureInPictureMediaPlayback", true)
        // Adds "Inspect Element" to the context menu.
        WebKitSPI.setPreference(prefs, "developerExtrasEnabled", true)

        if #available(macOS 15.4, *), AppSettings.shared.extensionsEnabled, !isPrivate || AppSettings.shared.extensionsInPrivate {
            config.webExtensionController = ExtensionManager.shared.controller
        }
        return config
    }

    static func makeWebView(configuration: WKWebViewConfiguration) -> VoidWebView {
        let wv = VoidWebView(frame: .zero, configuration: configuration)
        wv.isInspectable = true
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.allowsLinkPreview = true
        wv.autoresizingMask = [.width, .height]
        wv.underPageBackgroundColor = .clear
        return wv
    }
}

extension WKWebView {
    /// Calls an async JS function body in Void's world. Never throws and never hangs:
    /// returns nil on error or after `timeout` (a page promise may never settle).
    func voidCall(_ body: String, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil,
                  timeout: TimeInterval = 5) async -> Any? {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return await withCheckedContinuation { continuation in
            let finish: (Any?) -> Void = { value in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            callAsyncJavaScript(body, arguments: arguments, in: frame, in: WebViewFactory.world) { result in
                switch result {
                case .success(let value): finish(value)
                case .failure(let error):
                    NSLog("[Void] JS error: %@", error.localizedDescription)
                    finish(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}
