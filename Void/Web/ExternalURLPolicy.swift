import Foundation
#if os(macOS)
import AppKit
#endif

/// What to do with a link whose scheme belongs to another app (mailto:, zoommtg:, vscode:…).
enum ExternalURLPolicy: Equatable {
    case open, ask, refuse

    /// Schemes that mount network shares or open remote sessions: a web page never gets to
    /// trigger them (a smb:// link can leak the user's credentials to a hostile server).
    static let refusedSchemes: Set<String> = ["smb", "afp", "nfs", "cifs", "ftp", "ftps", "vnc", "ssh", "telnet",
                                             "file", "x-man-page"]
    /// Handed straight to the system app, as every browser does.
    static let trustedSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio", "maps"]

    /// Only a click of the user in the page itself (not in a frame of another site, not a script).
    static func decide(scheme: String, userClick: Bool, fromMainFrame: Bool) -> ExternalURLPolicy {
        let scheme = scheme.lowercased()
        guard userClick, fromMainFrame, !refusedSchemes.contains(scheme) else { return .refuse }
        return trustedSchemes.contains(scheme) ? .open : .ask
    }

    #if os(macOS)
    /// Asks before opening an app on behalf of `host`.
    @MainActor
    static func confirmAndOpen(_ url: URL, from host: String, in window: NSWindow?) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Ouvrir « \(name) » ?"
        alert.informativeText = "\(host.isEmpty ? "Cette page" : host) veut ouvrir un lien dans l'app \(name)."
        alert.addButton(withTitle: "Ouvrir")
        alert.addButton(withTitle: "Annuler")
        let open = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: open) } else { open(alert.runModal()) }
    }
    #endif
}
