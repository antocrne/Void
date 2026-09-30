import Foundation
import WebKit

/// Remembers what's typed in ordinary form fields (name, address, email…) and suggests it on
/// fields with the same name. Nothing is kept from private tabs; passwords go through PasswordManager.
@MainActor
final class FormAutofill {
    static let shared = FormAutofill()

    private static let defaultsKey = "formAutofillEntries"
    private static let maxValuesPerKey = 8
    private static let maxKeys = 300

    private var entries: [String: [String]]
    private var keyOrder: [String]

    private init() {
        entries = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
        keyOrder = UserDefaults.standard.stringArray(forKey: Self.defaultsKey + "Order") ?? Array(entries.keys)
    }

    /// Off when a password manager extension is running: it draws its own suggestions on the fields.
    var isEnabled: Bool { AppSettings.shared.formAutofillEnabled && PasswordManager.shared.otherManagerName == nil }

    func clear() {
        entries = [:]
        keyOrder = []
        persist()
    }

    func handle(_ body: [String: Any], frame: WKFrameInfo, tab: Tab) {
        guard isEnabled, !tab.isPrivate else { return }
        switch body["type"] as? String {
        case "save":
            for field in body["fields"] as? [[String: Any]] ?? [] {
                guard let key = field["key"] as? String, let value = field["value"] as? String else { continue }
                remember(value, for: key)
            }
            persist()
        case "suggest":
            guard let key = body["key"] as? String, let webView = tab.webView else { return }
            let values = entries[key] ?? []
            Task {
                _ = await webView.voidCall("window.__voidForm && window.__voidForm.suggestions(k, v);",
                                           arguments: ["k": key, "v": values], in: frame)
            }
        default:
            break
        }
    }

    private func remember(_ value: String, for key: String) {
        var values = entries[key] ?? []
        values.removeAll { $0 == value }
        values.insert(value, at: 0)
        entries[key] = Array(values.prefix(Self.maxValuesPerKey))
        keyOrder.removeAll { $0 == key }
        keyOrder.insert(key, at: 0)
        for old in keyOrder.dropFirst(Self.maxKeys) { entries[old] = nil }
        keyOrder = Array(keyOrder.prefix(Self.maxKeys))
    }

    private func persist() {
        UserDefaults.standard.set(entries, forKey: Self.defaultsKey)
        UserDefaults.standard.set(keyOrder, forKey: Self.defaultsKey + "Order")
    }
}
