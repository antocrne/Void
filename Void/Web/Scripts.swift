import Foundation

/// JavaScript sources bundled in Resources/Scripts.
enum Scripts {
    static let core = load("core")
    static let media = load("media")
    static let autofill = load("autofill")
    static let formfill = load("formfill")
    static let reader = load("reader")
    static let hider = load("hider")
    static let activity = load("activity")
    static let webstore = load("webstore").replacingOccurrences(of: "__VOID_STORE_LABELS__", with: json([
        "add": String(localized: "Ajouter à Void"),
        "adding": String(localized: "Ajout en cours…"),
        "remove": String(localized: "Retirer de Void"),
    ]))
    static let extensionShim = load("extension-shim")
    static let shareAudio = load("shareaudio")
    static let shareAudioPage = load("shareaudio-page")

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Missing script \(name).js")
            return ""
        }
        return source
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
