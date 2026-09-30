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
    static let webstore = load("webstore")
    static let extensionShim = load("extension-shim")

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Missing script \(name).js")
            return ""
        }
        return source
    }
}
