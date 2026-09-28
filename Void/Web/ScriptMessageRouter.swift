import WebKit

/// Receives every message posted by Void's scripts and dispatches it to the owning tab.
/// Handlers are registered once on the shared content controller, so the tab is found
/// from `message.webView` (popups inherit the opener's controller).
final class ScriptMessageRouter: NSObject, WKScriptMessageHandler {
    static let shared = ScriptMessageRouter()
    static let names = ["voidMedia", "voidAutofill", "voidHider", "voidContext", "voidActivity"]

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let webView = message.webView as? VoidWebView, let tab = webView.tab,
                  let body = message.body as? [String: Any] else { return }
            switch message.name {
            case "voidMedia":
                PiPController.shared.handleReport(body, frame: message.frameInfo, tab: tab)
            case "voidAutofill":
                PasswordManager.shared.handle(body, frame: message.frameInfo, tab: tab)
            case "voidHider":
                ElementHider.shared.handlePick(body, tab: tab)
            case "voidActivity":
                switch body["type"] as? String {
                case "scroll" where message.frameInfo.isMainFrame:
                    let value = min(1, max(0, body["value"] as? Double ?? 0))
                    if abs(value - tab.readingProgress) >= 0.004 || value == 0 || value == 1 { tab.readingProgress = value }
                case "input":
                    tab.hasUserInput = true
                default:
                    break
                }
            case "voidContext":
                webView.contextLinkURL = (body["href"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                webView.contextImageURL = (body["image"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            default:
                break
            }
        }
    }
}
