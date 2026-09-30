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
        webView.window?.makeFirstResponder(webView)
        Task {
            _ = await webView.voidCall("return (\n\(Scripts.hider)\n);", arguments: ["voidAccent": Theme.accentCSS.light])
        }
    }

    func handlePick(_ body: [String: Any], tab: Tab) {
        guard body["cancelled"] == nil,
              let selector = body["selector"] as? String, !selector.isEmpty,
              let host = body["host"] as? String, !host.isEmpty else { return }
        let key = host.voidNormalizedHost
        guard !(rules[key] ?? []).contains(selector) else { return }
        Task {
            // All hidden elements share one compiled list: a selector WebKit's content blocker
            // refuses would cost every one of them. It is tried on its own first.
            guard await ContentRules.shared.accepts(selector: selector) else {
                tab.browser?.showToast("exclamationmark.triangle", "Cet élément ne peut pas être masqué durablement")
                return
            }
            var list = rules[key] ?? []
            guard !list.contains(selector) else { return }
            list.append(selector)
            rules[key] = list
            save()
            tab.browser?.showToast("eye.slash", "Élément masqué sur \(key)")
        }
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
