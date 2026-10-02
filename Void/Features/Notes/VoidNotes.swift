import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Send to Void Notes" (⌘⇧M, context menu): hands a selection or the page to the companion
/// app through `voidnotes://new?title=…&text=…&url=…`. The system delivers the URL to Void Notes
/// when it is installed; without it the menu items stay visible but disabled.
@MainActor @Observable
final class VoidNotes {
    static let shared = VoidNotes()
    static let scheme = "voidnotes"
    static let missingHint = "Nécessite Void Notes"
    /// The note travels in a URL: a long page is cut rather than refused by LaunchServices.
    static let maxTextLength = 20_000

    /// Whether an app is registered for `voidnotes://`. Observed by the menu bar.
    private(set) var isInstalled = false

    #if DEBUG
    /// Self-test: pretends Void Notes is (not) installed.
    @ObservationIgnored var installedOverride: Bool? { didSet { refresh() } }
    /// Self-test: receives the note URL instead of LaunchServices; returns whether it "opened".
    @ObservationIgnored var openOverride: ((URL) -> Bool)?
    #endif

    private init() {
        refresh()
        // Void Notes installed or removed while Void runs: seen when the user comes back.
        #if os(macOS)
        let becameActive = NSApplication.didBecomeActiveNotification
        #else
        let becameActive = UIApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: becameActive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        #if os(macOS)
        var installed = URL(string: "\(Self.scheme)://new").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
        #else
        // Needs `voidnotes` in the Info.plist's LSApplicationQueriesSchemes.
        var installed = URL(string: "\(Self.scheme)://new").map { UIApplication.shared.canOpenURL($0) } ?? false
        #endif
        #if DEBUG
        if let installedOverride { installed = installedOverride }
        #endif
        if installed != isInstalled { isInstalled = installed }
    }

    /// Menu title: says why the item is disabled when Void Notes is missing.
    func menuTitle(_ title: String) -> String {
        isInstalled ? title : "\(title) — \(Self.missingHint.prefix(1).lowercased() + Self.missingHint.dropFirst())"
    }

    /// Every value is fully percent-encoded (`&`, `=`, `+`, line breaks…), so the receiver
    /// gets it back whichever way it parses the query.
    static func noteURL(title: String, text: String, url: URL?) -> URL? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = text.count > maxTextLength ? text.prefix(maxTextLength) + "…" : text
        let query = [("title", title), ("text", body), ("url", url?.absoluteString ?? "")]
            .filter { !$0.1.isEmpty }
            .compactMap { name, value in value.addingPercentEncoding(withAllowedCharacters: unreserved).map { "\(name)=\($0)" } }
            .joined(separator: "&")
        return URL(string: "\(scheme)://new" + (query.isEmpty ? "" : "?" + query))
    }

    /// New note: the selected text, the page it comes from and its title.
    func sendSelection(_ selection: String, from tab: Tab) {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(title: title(of: tab), text: text, url: tab.url ?? tab.webView?.url, from: tab)
    }

    /// New note: title, address and the article reader.js finds; title and link only on a
    /// page without one.
    func sendPage(from tab: Tab) {
        guard let url = tab.url ?? tab.webView?.url else {
            tab.browser?.showToast("note.text", "Aucune page à envoyer")
            return
        }
        refresh()
        guard isInstalled else {
            tab.browser?.showToast("note.text", Self.missingHint)
            return
        }
        let title = title(of: tab)
        Task {
            let article = await tab.webView?.voidCall("return (\n\(Scripts.reader)\n);") as? [String: Any]
            send(title: title, text: article?["text"] as? String ?? "", url: url, from: tab)
        }
    }

    private func title(of tab: Tab) -> String {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? (tab.url?.host() ?? "") : title
    }

    private func send(title: String, text: String, url: URL?, from tab: Tab) {
        let browser = tab.browser ?? BrowserWindows.shared.active
        refresh()
        guard isInstalled else {
            browser.showToast("note.text", Self.missingHint)
            return
        }
        guard let note = Self.noteURL(title: title, text: text, url: url) else {
            browser.showToast("exclamationmark.triangle", "Impossible d'envoyer vers Void Notes")
            return
        }
        let finish = { [weak browser] (opened: Bool) in
            if opened {
                browser?.showToast("note.text", "Envoyé vers Void Notes")
            } else {
                browser?.showToast("exclamationmark.triangle", "Impossible d'ouvrir Void Notes")
            }
        }
        #if DEBUG
        if let openOverride { finish(openOverride(note)); return }
        #endif
        #if os(macOS)
        NSWorkspace.shared.open(note, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("[Void] note non transmise à Void Notes : %@", error.localizedDescription) }
            let opened = error == nil
            DispatchQueue.main.async { finish(opened) }
        }
        #else
        UIApplication.shared.open(note) { opened in finish(opened) }
        #endif
    }
}
