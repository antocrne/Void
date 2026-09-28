import AppKit
import UniformTypeIdentifiers

enum DefaultBrowser {
    static var isDefault: Bool {
        guard let url = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks the user to confirm the change.
    static func makeDefault(completion: @escaping @Sendable (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html) { _ in }
            completion(error == nil)
        }
    }
}
