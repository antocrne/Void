import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Send to Void Notes" (⌘⇧M, context menu): hands a selection or the page to the companion
/// app through `voidnotes://new?title=…&text=…&url=…`. The system delivers the URL to Void Notes
/// when it is installed; without it the menu items stay visible but disabled. An image can't
/// travel in a URL: it goes on a named pasteboard that Void Notes reads (see `sendImage`).
/// On the Mac, what is sent can also go at the end of a note already written
/// (`voidnotes://append?note=…&…`): a panel shows the tree Void Notes leaves on another named
/// pasteboard (`directory()`), and one picks a note in it (NotesPicker).
@MainActor @Observable
final class VoidNotes {
    static let shared = VoidNotes()
    static let scheme = "voidnotes"
    static var missingHint: String { String(localized: "Nécessite Void Notes") }
    /// The note travels in a URL: a long page is cut rather than refused by LaunchServices.
    static let maxTextLength = 20_000
    /// The pasteboard an image is left on for Void Notes, which reads it and clears it. Named
    /// pasteboards are shared with sandboxed apps and read without the system's paste alert.
    static let imagePasteboard = "app.void.notes.incoming"
    /// Larger is refused rather than handed over.
    static let maxImageBytes = 30_000_000
    /// Where Void Notes lists the notes one can add to, as its list shows them (its `NoteDirectory`).
    static let directoryPasteboard = "app.void.notes.directory"

    /// What Void Notes lists: its spaces, the folders that lead to a note, and the notes one can
    /// add to — pinned, then the most recently changed; neither locked nor archived.
    struct Directory: Decodable, Equatable {
        struct Space: Decodable, Equatable, Identifiable {
            let id: UUID
            let name: String
            /// SF Symbol name.
            let icon: String
        }
        struct Folder: Decodable, Equatable, Identifiable {
            let id: UUID
            let name: String
            let icon: String
            let parent: UUID?
            let space: UUID?
        }
        var version = 2
        /// In Void Notes' order.
        let spaces: [Space]
        /// Each one followed by its subfolders, by name.
        let folders: [Folder]
        let notes: [NoteTarget]
    }

    /// A note of Void Notes that can be added to.
    struct NoteTarget: Decodable, Equatable, Identifiable {
        let id: UUID
        let title: String
        let space: UUID?
        let folder: UUID?
        let pinned: Bool
    }

    /// What is sent.
    enum Content: Equatable {
        case selection(String)
        case page
        case image(URL)
    }

    /// Whether an app is registered for `voidnotes://`. Observed by the menu bar.
    private(set) var isInstalled = false

    #if DEBUG
    /// Self-test: pretends Void Notes is (not) installed.
    @ObservationIgnored var installedOverride: Bool? { didSet { refresh() } }
    /// Self-test: receives the note URL instead of LaunchServices; returns whether it "opened".
    @ObservationIgnored var openOverride: ((URL) -> Bool)?
    /// Self-test: what Void Notes would list; without notes, as if it listed nothing.
    @ObservationIgnored var directoryOverride: Directory?
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
    func menuTitle(_ title: LocalizedStringResource) -> String {
        let title = String(localized: title)
        return isInstalled ? title : String(localized: "\(title) — nécessite Void Notes")
    }

    /// The notes Void Notes offers to add to, in their tree; nil when it hasn't said (not
    /// launched since the Mac started, or an older version) or lists none.
    func directory() -> Directory? {
        #if DEBUG
        if let directoryOverride { return directoryOverride.notes.isEmpty ? nil : directoryOverride }
        #endif
        #if os(macOS)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(Self.directoryPasteboard))
        guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(Self.directoryPasteboard)),
              let directory = try? JSONDecoder().decode(Directory.self, from: data), directory.version == 2,
              !directory.spaces.isEmpty, directory.notes.contains(where: { !$0.title.isEmpty }) else { return nil }
        return Directory(spaces: directory.spaces, folders: directory.folders, notes: directory.notes.filter { !$0.title.isEmpty })
        #else
        return nil
        #endif
    }

    /// Sending from a tab: to a new note — or, when Void Notes lists notes, through the panel
    /// where one picks a note or a new one.
    func send(_ content: Content, from tab: Tab) {
        let browser = tab.browser ?? BrowserWindows.shared.active
        refresh()
        guard isInstalled, let directory = directory() else {
            deliver(content, from: tab, to: nil)
            return
        }
        browser.commandBar = nil
        browser.notesPicker = NotesPickerRequest(content: content, tab: tab, directory: directory)
    }

    /// `note`: the note to add to; nil, a new one.
    func deliver(_ content: Content, from tab: Tab, to note: NoteTarget?) {
        switch content {
        case .selection(let text): sendSelection(text, from: tab, to: note)
        case .page: sendPage(from: tab, to: note)
        case .image(let source): sendImage(source, from: tab, to: note)
        }
    }

    /// Every value is fully percent-encoded (`&`, `=`, `+`, line breaks…), so the receiver
    /// gets it back whichever way it parses the query.
    /// `image`: the name of the image left on `imagePasteboard`. `note`: the note to add to,
    /// rather than a new one.
    static func noteURL(title: String, text: String, url: URL?, image: String? = nil, note: UUID? = nil) -> URL? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = text.count > maxTextLength ? text.prefix(maxTextLength) + "…" : text
        let query = [("note", note?.uuidString ?? ""), ("title", title), ("text", body), ("url", url?.absoluteString ?? ""), ("image", image ?? "")]
            .filter { !$0.1.isEmpty }
            .compactMap { name, value in value.addingPercentEncoding(withAllowedCharacters: unreserved).map { "\(name)=\($0)" } }
            .joined(separator: "&")
        return URL(string: "\(scheme)://\(note == nil ? "new" : "append")" + (query.isEmpty ? "" : "?" + query))
    }

    /// New note — or added to `note`: the selected text, the page it comes from and its title.
    func sendSelection(_ selection: String, from tab: Tab, to note: NoteTarget? = nil) {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(title: title(of: tab), text: text, url: tab.url ?? tab.webView?.url, to: note, from: tab)
    }

    /// New note — or added to `note`: title, address and the article reader.js finds; title
    /// and link only on a page without one.
    func sendPage(from tab: Tab, to note: NoteTarget? = nil) {
        guard let url = tab.url ?? tab.webView?.url else {
            tab.browser?.showToast("note.text", "Aucune page à envoyer")
            return
        }
        refresh()
        guard isInstalled else {
            tab.browser?.showToast("note.text", verbatim: Self.missingHint)
            return
        }
        let title = title(of: tab)
        Task {
            let article = await tab.webView?.voidCall("return (\n\(Scripts.reader)\n);") as? [String: Any]
            send(title: title, text: article?["text"] as? String ?? "", url: url, to: note, from: tab)
        }
    }

    /// New note — or added to `note`: the image under the right-click, the page it is on and its title.
    func sendImage(_ source: URL, from tab: Tab, to note: NoteTarget? = nil) {
        let browser = tab.browser ?? BrowserWindows.shared.active
        refresh()
        guard isInstalled else {
            browser.showToast("note.text", verbatim: Self.missingHint)
            return
        }
        let title = title(of: tab), page = tab.url ?? tab.webView?.url
        Task {
            guard let image = await Self.loadImage(source, in: tab) else {
                browser.showToast("exclamationmark.triangle", "Impossible de récupérer l'image")
                return
            }
            Self.leaveOnPasteboard(image)
            send(title: title, text: "", url: page, image: image.name, to: note, from: tab)
        }
    }

    struct NoteImage {
        let data: Data
        let type: UTType
        /// File name in the note: the one of the address, or "Image", with the extension of its format.
        let name: String
    }

    /// The bytes of the image, as the page got them: with the tab's cookies (an image behind a
    /// login), from the page itself for a `blob:` it made — and for an image outside WebKit's
    /// reach (plain `http:`, refused by App Transport Security) that the page may read.
    static func loadImage(_ source: URL, in tab: Tab) async -> NoteImage? {
        var data: Data?
        switch source.scheme?.lowercased() {
        case "blob":
            data = await fetchInPage(source, in: tab)
        case "http", "https":
            data = await download(source, in: tab)
            if data == nil { data = await fetchInPage(source, in: tab) }
        case "data":
            data = await download(source, in: tab)
        default:
            break
        }
        guard let data, data.count <= maxImageBytes else { return nil }
        return image(from: data, source: source)
    }

    private static func fetchInPage(_ source: URL, in tab: Tab) async -> Data? {
        let base64 = await tab.webView?.voidCall("""
            const response = await fetch(src, {credentials: 'include'});
            if (!response.ok) return null;
            const blob = await response.blob();
            if (blob.size > max) return null;
            return await new Promise((done) => {
              const reader = new FileReader();
              reader.onload = () => done(String(reader.result).split(',')[1] || null);
              reader.onerror = () => done(null);
              reader.readAsDataURL(blob);
            });
            """, arguments: ["src": source.absoluteString, "max": maxImageBytes], timeout: 15) as? String
        return base64.flatMap { Data(base64Encoded: $0) }
    }

    private static func download(_ source: URL, in tab: Tab) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        if let cookies = await tab.webView?.configuration.websiteDataStore.httpCookieStore.allCookies() {
            cookies.forEach { configuration.httpCookieStorage?.setCookie($0) }
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: source, timeoutInterval: 20)
        request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        if let agent = tab.webView?.customUserAgent, !agent.isEmpty { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        // Sites that refuse their images to other sites check where the request comes from:
        // the whole address for the same site, only the origin for another (as a browser does).
        if let page = tab.url ?? tab.webView?.url, ["http", "https"].contains(page.scheme?.lowercased() ?? ""), let host = page.host() {
            let referer = source.host() == host ? page.absoluteString : "\(page.scheme ?? "https")://\(host)/"
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }

    /// nil: not an image ImageIO reads (Void Notes shows it with ImageIO). An SVG is drawn into a PNG.
    static func image(from data: Data, source: URL) -> NoteImage? {
        var data = data
        var type = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceGetCount($0) > 0 ? CGImageSourceGetType($0) : nil }
            .flatMap { UTType($0 as String) }
        #if os(macOS)
        if type == nil, let picture = NSImage(data: data), let tiff = picture.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            data = png
            type = .png
        }
        #endif
        guard let type, type.conforms(to: .image), let ext = type.preferredFilenameExtension else { return nil }
        var base = ""
        if ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
            base = (source.lastPathComponent as NSString).deletingPathExtension
            base = (base.removingPercentEncoding ?? base).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            base = String(base.trimmingCharacters(in: .whitespaces).prefix(80))
        }
        return NoteImage(data: data, type: type, name: (base.isEmpty ? "Image" : base) + "." + ext)
    }

    private static func leaveOnPasteboard(_ image: NoteImage) {
        #if os(macOS)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(imagePasteboard))
        pasteboard.clearContents()
        pasteboard.setData(image.data, forType: NSPasteboard.PasteboardType(image.type.identifier))
        #else
        UIPasteboard(name: UIPasteboard.Name(imagePasteboard), create: true)?.setData(image.data, forPasteboardType: image.type.identifier)
        #endif
    }

    private func title(of tab: Tab) -> String {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? (tab.url?.host() ?? "") : title
    }

    private func send(title: String, text: String, url: URL?, image: String? = nil, to target: NoteTarget? = nil, from tab: Tab) {
        let browser = tab.browser ?? BrowserWindows.shared.active
        refresh()
        guard isInstalled else {
            browser.showToast("note.text", verbatim: Self.missingHint)
            return
        }
        guard let note = Self.noteURL(title: title, text: text, url: url, image: image, note: target?.id) else {
            browser.showToast("exclamationmark.triangle", "Impossible d'envoyer vers Void Notes")
            return
        }
        let finish = { [weak browser] (opened: Bool) in
            if let target, opened {
                browser?.showToast("note.text", "Ajouté à « \(target.title) »")
            } else if opened {
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
