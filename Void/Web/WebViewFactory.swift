import WebKit
#if os(iOS)
import UIKit
#endif

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
        #if os(macOS)
        // Sound in screen sharing: the page's getDisplayMedia is wrapped in its own world.
        ucc.addScriptMessageHandler(ShareAudio.shared, contentWorld: world, name: ShareAudio.messageName)
        ucc.addUserScript(WKUserScript(source: Scripts.shareAudio, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        ucc.addUserScript(WKUserScript(source: Scripts.shareAudioPage, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        if #available(macOS 15.4, *) {
            // "Ajouter à Void" on the Chrome Web Store's extension pages.
            ucc.addUserScript(WKUserScript(source: Scripts.webstore, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        }
        #endif
        return ucc
    }()

    /// "Version/x Safari/605.1.15": without it many sites (video players, Google) serve a degraded page.
    static let userAgentSuffix: String = {
        #if os(macOS)
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(safari ?? "18.0") Safari/605.1.15"
        #else
        // Safari's version is the system's. An iPad asks for desktop pages, as Safari does there.
        let version = UIDevice.current.systemVersion
        return isPad ? "Version/\(version) Safari/605.1.15" : "Version/\(version) Mobile/15E148 Safari/604.1"
        #endif
    }()

    #if os(iOS)
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    #endif

    /// `url`: the page the web view will show first — an extension's page gets the extension's configuration.
    static func configuration(for space: Space?, isPrivate: Bool, url: URL? = nil) -> WKWebViewConfiguration {
        #if os(macOS)
        if #available(macOS 15.4, *), let extensionPage = ExtensionManager.running?.configuration(for: url) {
            return extensionPage
        }
        #endif
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        // Normal windows: the space's persistent store. Private windows: their space's in-memory
        // store, shared by all the window's tabs and gone when the window closes.
        if let space {
            config.websiteDataStore = space.dataStore
        } else {
            config.websiteDataStore = isPrivate ? .nonPersistent() : BrowserModel.shared.currentSpace.dataStore
        }
        #if os(macOS)
        WebCryptoMasterKey.shared.attach(to: config.websiteDataStore)
        #endif
        config.applicationNameForUserAgent = userAgentSuffix
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = AppSettings.shared.blockAutoplayWithSound ? .audio : []
        let prefs = config.preferences
        prefs.isElementFullscreenEnabled = true
        // New windows only in answer to a click, as in Safari (WebKit's default on macOS lets a page
        // open tabs at load or from a timer: pop-unders).
        prefs.javaScriptCanOpenWindowsAutomatically = false
        prefs.isFraudulentWebsiteWarningEnabled = true
        #if os(macOS)
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // PiP: on macOS there is no public switch (allowsPictureInPictureMediaPlayback is iOS-only).
        // WebKit's internal preference defaults to YES; set it explicitly when available.
        WebKitSPI.setPreference(prefs, "allowsPictureInPictureMediaPlayback", true)
        // Adds "Inspect Element" to the context menu.
        WebKitSPI.setPreference(prefs, "developerExtrasEnabled", true)

        if #available(macOS 15.4, *), AppSettings.shared.extensionsEnabled, !isPrivate || AppSettings.shared.extensionsInPrivate {
            config.webExtensionController = ExtensionManager.shared.controller
        }
        #else
        config.defaultWebpagePreferences.preferredContentMode = isPad ? .desktop : .mobile
        // Videos play in the page (not full screen at once) and can go to Picture in Picture.
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        #endif
        return config
    }

    static func makeWebView(configuration: WKWebViewConfiguration) -> VoidWebView {
        let wv = VoidWebView(frame: .zero, configuration: configuration)
        wv.isInspectable = true
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = true
        #if os(macOS)
        wv.allowsMagnification = true
        wv.autoresizingMask = [.width, .height]
        #else
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.isFindInteractionEnabled = true
        // iOS keeps WebKit's default: the page's own background colour, which also fills the
        // status bar area above the page, as in Safari.
        #endif
        #if os(macOS)
        wv.underPageBackgroundColor = .clear
        #endif
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
