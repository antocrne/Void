import Foundation
import WebKit

/// "Hide element" (⌘⇧H): the user clicks an element, it disappears now and on every
/// future visit of the site, through a compiled content rule (no script at load time).
@MainActor
final class ElementHider {
    static let shared = ElementHider()

    /// host (without www.) → CSS selectors
    private(set) var rules: [String: [String]]
    private let fileURL = StateStore.directory.appendingPathComponent("hidden-elements.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            rules = decoded
        } else {
            rules = [:]
        }
    }

    func startPicking(in tab: Tab) {
        guard let webView = tab.webView else { return }
        let browser = tab.browser
        browser?.isPickingElement = true
        webView.window?.makeFirstResponder(webView)
        Task {
            let result = await webView.voidCall("return (\n\(Scripts.hider)\n);", arguments: ["voidAccent": Theme.accentCSS.light]) as? String
            if result == nil { browser?.isPickingElement = false }
        }
    }

    func handlePick(_ body: [String: Any], tab: Tab) {
        tab.browser?.isPickingElement = false
        guard body["cancelled"] == nil,
              let selector = body["selector"] as? String, !selector.isEmpty,
              let host = body["host"] as? String, !host.isEmpty else { return }
        let key = host.voidNormalizedHost
        var list = rules[key] ?? []
        guard !list.contains(selector) else { return }
        list.append(selector)
        rules[key] = list
        save()
        tab.browser?.showToast("eye.slash", "Élément masqué sur \(key)")
    }

    func reset(host: String) {
        rules[host] = nil
        save()
    }

    func resetAll() {
        rules = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) { try? data.write(to: fileURL, options: .atomic) }
        ContentRules.shared.reloadHidden()
    }

    func encodedRules() -> String {
        let list: [[String: Any]] = rules.sorted { $0.key < $1.key }.compactMap { host, selectors in
            guard !selectors.isEmpty else { return nil }
            return [
                "trigger": ["url-filter": ".*", "if-domain": ["*" + host]],
                "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")],
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
