import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation

@MainActor @Observable
final class DownloadItem: Identifiable {
    enum State: Equatable { case running, paused, finished, failed(String), cancelled }

    let id = UUID()
    var filename: String
    let sourceURL: URL?
    var destination: URL?
    var progress: Double = 0
    var state: State = .running
    let started = Date()
    /// Started from a private window: never listed in the downloads history.
    let isPrivate: Bool
    @ObservationIgnored weak var browser: BrowserModel?
    @ObservationIgnored var download: WKDownload?
    @ObservationIgnored var observation: NSKeyValueObservation?
    /// The server can send the rest of the file later: it takes byte ranges and tells whether the
    /// file changed meanwhile (ETag / Last-Modified). Only then is "Pause" offered.
    var canPause = false
    /// What WebKit needs to go on from where it stopped: kept while paused, and after a failure
    /// it can recover from (connection lost). The partial file stays at `destination` meanwhile.
    var resumeData: Data?
    /// Asks where to save the file instead of using the download folder (on iOS: once downloaded).
    @ObservationIgnored var asksDestination = false
    /// The website data store of the page that started it: a resumed download uses its cookies.
    @ObservationIgnored var store: WKWebsiteDataStore?
    /// Runs the download once resumed (the tab it came from may be gone).
    @ObservationIgnored var resumingWebView: WKWebView?
    /// Bytes received so far, and the file's size when the server gives it (0 otherwise).
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// Current speed, smoothed over the last seconds (0 until a first measure).
    var bytesPerSecond: Double = 0
    @ObservationIgnored private var lastSample: (date: Date, bytes: Int64)?

    var canResume: Bool {
        guard resumeData != nil else { return false }
        if case .failed = state { return true }
        return state == .paused
    }

    /// Reads a progress report from WebKit. The speed is measured at most twice a second.
    func update(received: Int64, total: Int64) {
        // A resumed download first reports 0: the bytes already there still count.
        guard received >= receivedBytes else { return }
        let now = Date()
        totalBytes = max(0, total)
        guard let last = lastSample else {
            lastSample = (now, received)
            receivedBytes = received
            return
        }
        let elapsed = now.timeIntervalSince(last.date)
        guard elapsed >= 0.5 || (total > 0 && received >= total) else { return }
        receivedBytes = received
        let instant = Double(max(0, received - last.bytes)) / max(elapsed, 0.001)
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.6 + instant * 0.4
        lastSample = (now, received)
        if total > 0 { progress = Double(received) / Double(total) }
    }

    /// Speed is measured afresh once resumed.
    func resetSpeed() {
        lastSample = nil
        bytesPerSecond = 0
    }

    /// "12,4 Mo sur 80 Mo".
    private var sizeText: String {
        let size = ByteCountFormatter()
        size.countStyle = .file
        return totalBytes > 0 ? "\(size.string(fromByteCount: receivedBytes)) sur \(size.string(fromByteCount: totalBytes))"
                              : size.string(fromByteCount: receivedBytes)
    }

    /// "En pause · 12,4 Mo sur 80 Mo".
    var pausedText: String { receivedBytes > 0 ? "En pause · \(sizeText)" : "En pause" }

    /// "12,4 Mo sur 80 Mo · 3,1 Mo/s · 18 s restantes", as much as is known.
    var statusText: String {
        let size = ByteCountFormatter()
        size.countStyle = .file
        var parts = [sizeText]
        if bytesPerSecond > 0 {
            parts.append("\(size.string(fromByteCount: Int64(bytesPerSecond)))/s")
            if totalBytes > receivedBytes {
                let remaining = Double(totalBytes - receivedBytes) / bytesPerSecond
                let time = DateComponentsFormatter()
                time.unitsStyle = .abbreviated
                time.maximumUnitCount = remaining >= 3600 ? 2 : 1
                time.allowedUnits = [.hour, .minute, .second]
                if let text = time.string(from: max(1, remaining.rounded())) { parts.append("\(text) restantes") }
            }
        }
        return parts.joined(separator: " · ")
    }

    /// "Terminé · 80 Mo".
    var finishedText: String {
        receivedBytes > 0 ? "Terminé · \(ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file))" : "Terminé"
    }

    init(filename: String, sourceURL: URL?, browser: BrowserModel?) {
        self.filename = filename
        self.sourceURL = sourceURL
        self.browser = browser
        self.isPrivate = browser?.isPrivate ?? false
    }
}

/// Downloads go to the download folder (Settings → Téléchargements, ~/Downloads by default; unique
/// names) unless the user asks where to save them, with progress in the Library. They can be paused
/// when the server allows it. Downloads of a private window are only shown in that window and
/// forgotten when it closes (the file itself stays in the folder).
@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()
    private(set) var items: [DownloadItem] = []
    @ObservationIgnored private let delegate = DownloadDelegate()

    var activeCount: Int { items.filter { $0.state == .running }.count }
    /// Running or paused: lost if Void quits.
    var unfinishedCount: Int { items.filter { $0.state == .running || $0.state == .paused }.count }

    /// The downloads history: everything except private windows' downloads.
    var history: [DownloadItem] { items.filter { !$0.isPrivate } }

    func items(of browser: BrowserModel) -> [DownloadItem] { items.filter { $0.browser === browser } }
    func activeCount(for browser: BrowserModel) -> Int {
        browser.isPrivate ? items(of: browser).filter { $0.state == .running }.count : history.filter { $0.state == .running }.count
    }

    /// "2 en cours · 4,2 Mo/s" while something downloads.
    func speedText(for browser: BrowserModel) -> String? {
        let running = (browser.isPrivate ? items(of: browser) : history).filter { $0.state == .running }
        guard !running.isEmpty else { return nil }
        let speed = running.reduce(0) { $0 + $1.bytesPerSecond }
        let count = running.count == 1 ? "1 en cours" : "\(running.count) en cours"
        return speed > 0 ? "\(count) · \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s" : count
    }

    /// `askingWhere`: "Télécharger le fichier lié sous…"; otherwise the setting decides.
    func adopt(_ download: WKDownload, from url: URL?, in browser: BrowserModel?, askingWhere: Bool = false) {
        let item = DownloadItem(filename: url?.lastPathComponent ?? "Téléchargement", sourceURL: url, browser: browser)
        item.asksDestination = askingWhere || AppSettings.shared.askDownloadLocation
        item.store = download.webView?.configuration.websiteDataStore
        attach(download, to: item)
        items.insert(item, at: 0)
        (browser ?? .shared).showToast("arrow.down.circle", "Téléchargement de \(item.filename)")
    }

    private func attach(_ download: WKDownload, to item: DownloadItem) {
        item.download = download
        item.observation = download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak item] progress, _ in
            let (received, total) = (progress.completedUnitCount, progress.totalUnitCount)
            DispatchQueue.main.async { item?.update(received: received, total: total) }
        }
        download.delegate = delegate
    }

    func item(for download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }

    /// Stops the transfer and keeps what's needed to go on later; the partial file stays.
    func pause(_ item: DownloadItem) {
        guard item.state == .running, item.canPause, let download = item.download else { return }
        item.state = .paused
        item.bytesPerSecond = 0
        download.cancel { [weak self] data in
            MainActor.assumeIsolated {
                item.observation = nil
                guard item.state == .paused else { self?.discardPartialFile(of: item); return }   // cancelled meanwhile
                if let data {
                    item.resumeData = data
                } else {
                    self?.discardPartialFile(of: item)
                    item.state = .failed("Ce site ne permet pas de reprendre le téléchargement")
                }
            }
        }
    }

    /// Goes on from where it stopped (paused, or interrupted by a lost connection), with the
    /// cookies of the page it came from.
    func resume(_ item: DownloadItem) {
        guard item.canResume, let data = item.resumeData else { return }
        item.resumeData = nil
        item.state = .running
        item.resetSpeed()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = item.store ?? (item.isPrivate ? .nonPersistent() : .default())
        let webView = WKWebView(frame: .zero, configuration: configuration)
        item.resumingWebView = webView
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            MainActor.assumeIsolated {
                guard item.state == .running else { download.cancel { _ in }; return }   // cancelled meanwhile
                self?.attach(download, to: item)
            }
        }
    }

    func cancel(_ item: DownloadItem) {
        let previous = item.state
        item.state = .cancelled
        item.bytesPerSecond = 0
        switch previous {
        case .finished, .cancelled:
            DownloadManager.release(item.destination)
        case .running:
            // The partial file goes once WebKit has stopped writing it.
            if let download = item.download {
                download.cancel { [weak self] _ in MainActor.assumeIsolated { self?.discardPartialFile(of: item) } }
            } else {
                discardPartialFile(of: item)
            }
        case .paused, .failed:
            discardPartialFile(of: item)
        }
    }

    /// The download asked where to save and the user cancelled: it leaves no trace in the list.
    fileprivate func remove(_ item: DownloadItem) {
        items.removeAll { $0 === item }
    }

    /// A download that won't finish: no truncated file left behind that could pass for the real one.
    fileprivate func discardPartialFile(of item: DownloadItem) {
        item.resumeData = nil
        item.resumingWebView = nil
        guard let file = item.destination else { return }
        DownloadManager.release(file)
        DownloadManager.setUnfinished(file, false)
        try? FileManager.default.removeItem(at: file)
    }

    #if os(macOS)
    func reveal(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.open(url)
    }

    /// "Enregistrer sous", over `window` when there is one. A file chosen to be replaced (the panel
    /// asked) goes to the Trash: WebKit won't write over an existing file.
    static func chooseLocation(for filename: String, in folder: URL, window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Enregistrer"
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let url = panel.url else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        return url
    }

    /// Moves a downloaded file elsewhere ("Déplacer vers…").
    func move(_ item: DownloadItem) {
        guard item.state == .finished, let file = item.destination, FileManager.default.fileExists(atPath: file.path) else { return }
        Task {
            guard let target = await Self.chooseLocation(for: file.lastPathComponent, in: file.deletingLastPathComponent(),
                                                         window: NSApp.keyWindow),
                  target.standardizedFileURL != file.standardizedFileURL else { return }
            do {
                try FileManager.default.moveItem(at: file, to: target)
                item.destination = target
                item.filename = target.lastPathComponent
            } catch {
                (item.browser ?? .shared).showToast("exclamationmark.triangle", "Déplacement impossible : \(error.localizedDescription)")
            }
        }
    }
    #else
    func reveal(_ item: DownloadItem) { open(item) }

    /// Quick Look, over the browser.
    func open(_ item: DownloadItem) {
        guard item.state == .finished, let url = item.destination, FileManager.default.fileExists(atPath: url.path) else { return }
        BrowserWindows.shared.previewedFile = url
    }

    @ObservationIgnored private var exporter: FileExporter?

    /// Moves a downloaded file to a folder chosen in Files (iCloud Drive, another app's folder…).
    /// Void keeps access to it there, for Quick Look.
    func move(_ item: DownloadItem) {
        guard item.state == .finished, let file = item.destination, FileManager.default.fileExists(atPath: file.path),
              let presenter = Dialogs.presenter else { return }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: false)
        let exporter = FileExporter { [weak self, weak item] urls in
            self?.exporter = nil
            guard let item, let target = urls.first else { return }
            _ = target.startAccessingSecurityScopedResource()
            item.destination = target
            item.filename = target.lastPathComponent
        }
        picker.delegate = exporter
        self.exporter = exporter
        presenter.present(picker, animated: true)
    }
    #endif

    func clearFinished() {
        let cleared = items.filter { $0.state != .running && $0.state != .paused && !$0.isPrivate }
        for item in cleared where item.resumeData != nil { discardPartialFile(of: item) }
        items.removeAll { item in cleared.contains { $0 === item } }
    }

    /// A private window closed: stop what isn't done and forget its list.
    func forget(browser: BrowserModel) {
        for item in items(of: browser) where item.state != .finished && item.state != .cancelled { cancel(item) }
        items.removeAll { $0.browser === browser || ($0.isPrivate && $0.browser == nil) }
    }

    // MARK: Unfinished files

    /// Paths of downloads that haven't finished (private ones aside: no trace of them is written).
    /// A paused download can't go on after a relaunch: what's left of these files is removed.
    private static let unfinishedKey = "unfinishedDownloads"

    fileprivate static func setUnfinished(_ file: URL, _ unfinished: Bool) {
        var paths = Set(UserDefaults.standard.stringArray(forKey: unfinishedKey) ?? [])
        if unfinished { paths.insert(file.path) } else { paths.remove(file.path) }
        UserDefaults.standard.set(Array(paths), forKey: unfinishedKey)
    }

    /// At launch (left by a crash or a quit) and at quit (running and paused downloads end here).
    func removeUnfinishedFiles() {
        for item in items where item.state == .running || item.state == .paused || item.canResume {
            if let file = item.destination { try? FileManager.default.removeItem(at: file) }
        }
        for path in UserDefaults.standard.stringArray(forKey: Self.unfinishedKey) ?? [] {
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.removeObject(forKey: Self.unfinishedKey)
    }

    /// A file name that can't pass for something else or hide: no path separators, no control
    /// characters, no bidirectional overrides ("facture\u{202E}fdp.app" displays as "facture ppa.pdf"),
    /// no leading dot (hidden file), at most 200 characters with the extension kept.
    static func sanitizedFilename(_ filename: String) -> String {
        let invisible: Set<UInt32> = [0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                      0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF]
        var name = String(String.UnicodeScalarView(filename.unicodeScalars.filter {
            !invisible.contains($0.value) && !CharacterSet.controlCharacters.contains($0)
        }))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 200 {
            let ext = (name as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 20 ? "" : "." + ext
            name = String(name.prefix(200 - keep.count)) + keep
        }
        return name.isEmpty ? "Téléchargement" : name
    }

    /// Destinations of downloads still running: two downloads of the same name must not get the
    /// same path while neither file exists yet.
    private static var reserved: Set<String> = []

    static func uniqueDestination(for filename: String, in folder: URL? = nil) -> URL {
        let folder = folder ?? AppSettings.shared.downloadFolder
        var candidate = folder.appendingPathComponent(sanitizedFilename(filename))
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        reserved.insert(candidate.path)
        return candidate
    }

    static func release(_ destination: URL?) {
        if let destination { reserved.remove(destination.path) }
    }

    /// Marks a downloaded file as coming from the web, so that Gatekeeper checks it before it is
    /// first opened (Void isn't sandboxed: nothing else guarantees it). Returns whether the file
    /// already carried a quarantine before Void looked at it.
    @discardableResult
    static func quarantine(_ file: URL, source: URL?) -> Bool {
        #if os(macOS)
        var url = file
        if (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil { return true }
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Void",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source, ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
            properties[kLSQuarantineDataURLKey as String] = source
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        do { try url.setResourceValues(values) } catch { NSLog("[Void] quarantaine impossible : %@", error.localizedDescription) }
        return false
        #else
        return true   // iOS apps are sandboxed: a downloaded file can't be run
        #endif
    }
}

/// Which sites may save files (asked once per site, as Safari does): without it any page could
/// fill the download folder, even with no click (a download link clicked by a script, in a loop).
/// Downloads asked from the context menu ("Télécharger le fichier lié…") never ask.
@MainActor
enum DownloadPermission {
    private static let key = "downloadAllowedHosts"

    static func isAllowed(_ host: String, in browser: BrowserModel) -> Bool {
        if browser.isPrivate { return browser.allowedDownloadHosts.contains(host) }
        return (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(host)
    }

    /// A private window's answers are forgotten with it.
    static func allow(_ host: String, in browser: BrowserModel) {
        if browser.isPrivate { browser.allowedDownloadHosts.insert(host); return }
        var hosts = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !hosts.contains(host) { hosts.append(host) }
        UserDefaults.standard.set(hosts, forKey: key)
    }

    static var allowedHosts: [String] { (UserDefaults.standard.stringArray(forKey: key) ?? []).sorted() }

    static func revoke(_ host: String) {
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != host }, forKey: key)
    }

    /// Questions on screen, by site: a second download of the same site meanwhile (several files
    /// at once, a file and its retry) waits for the same answer instead of being refused.
    private static var asking: [String: Task<Bool, Never>] = [:]

    #if os(macOS)
    /// `host`: the site of the page asking (normalized). `file`: what it wants to save, if known.
    /// `window`: where to ask; a tab not on screen (opened in the background, or not yet shown)
    /// asks over its browser's window.
    static func request(_ host: String, file: String?, in browser: BrowserModel, window: NSWindow?) async -> Bool {
        #if DEBUG
        if SelfTestRunner.isRequested { return true }
        #endif
        if host.isEmpty || isAllowed(host, in: browser) { return true }
        if let pending = asking[host] { return await pending.value }
        guard let window = window ?? browser.window else { return false }
        let task = Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Autoriser les téléchargements depuis « \(host) » ?"
            alert.informativeText = (file.map { "Ce site veut enregistrer « \($0) » dans votre dossier de téléchargements." }
                ?? "Ce site veut enregistrer un fichier dans votre dossier de téléchargements.")
                + (browser.isPrivate ? " (Jusqu'à la fermeture de cette fenêtre privée.)" : " Réglages → Téléchargements permet de revenir sur ce choix.")
            alert.addButton(withTitle: "Autoriser")
            alert.addButton(withTitle: "Refuser")
            let allowed = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
            if allowed { allow(host, in: browser) }
            return allowed
        }
        asking[host] = task
        defer { asking[host] = nil }
        return await task.value
    }
    #else
    /// `host`: the site of the page asking (normalized). `file`: what it wants to save, if known.
    static func request(_ host: String, file: String?, in browser: BrowserModel) async -> Bool {
        if host.isEmpty || isAllowed(host, in: browser) { return true }
        if let pending = asking[host] { return await pending.value }
        let task = Task { @MainActor in
            let message = (file.map { "Ce site veut enregistrer « \($0) » dans les fichiers de Void." }
                ?? "Ce site veut enregistrer un fichier dans les fichiers de Void.")
                + (browser.isPrivate ? " (Jusqu'à la fermeture de la navigation privée.)" : " Réglages → Téléchargements permet de revenir sur ce choix.")
            let allowed = await Dialogs.confirm(title: "Autoriser les téléchargements depuis « \(host) » ?", message: message,
                                                confirm: "Autoriser", cancel: "Refuser") ?? false
            if allowed { allow(host, in: browser) }
            return allowed
        }
        asking[host] = task
        defer { asking[host] = nil }
        return await task.value
    }
    #endif
}

@MainActor
private final class DownloadDelegate: NSObject, WKDownloadDelegate {
    /// Not asked again when a paused download resumes: WebKit goes on in the same file.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let manager = DownloadManager.shared
        let item = manager.item(for: download)
        var destination: URL?
        #if os(macOS)
        if let item, item.asksDestination {
            let window = item.browser?.window ?? NSApp.keyWindow
            guard let chosen = await DownloadManager.chooseLocation(for: DownloadManager.sanitizedFilename(suggestedFilename),
                                                                   in: AppSettings.shared.downloadFolder, window: window) else {
                manager.remove(item)
                return nil
            }
            destination = chosen
        }
        #endif
        let file = destination ?? DownloadManager.uniqueDestination(for: suggestedFilename)
        if let item {
            item.filename = file.lastPathComponent
            item.destination = file
            item.canPause = Self.canResume(response, request: download.originalRequest)
            if !item.isPrivate { DownloadManager.setUnfinished(file, true) }
        }
        return file
    }

    /// What URLSession needs to resume: a GET, byte ranges, and a validator telling the file
    /// hasn't changed meanwhile.
    private static func canResume(_ response: URLResponse, request: URLRequest?) -> Bool {
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
              (request?.httpMethod ?? "GET").uppercased() == "GET" else { return false }
        let ranges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
        return ranges && (http.value(forHTTPHeaderField: "ETag") != nil || http.value(forHTTPHeaderField: "Last-Modified") != nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = DownloadManager.shared.item(for: download) else { return }
        item.state = .finished
        item.progress = 1
        if let progress = item.download?.progress { item.receivedBytes = max(item.receivedBytes, progress.completedUnitCount) }
        item.bytesPerSecond = 0
        item.resumingWebView = nil
        DownloadManager.release(item.destination)
        if let destination = item.destination {
            DownloadManager.setUnfinished(destination, false)
            let already = DownloadManager.quarantine(destination, source: item.sourceURL)
            NSLog("[Void] téléchargement terminé, quarantaine %@", already ? "déjà posée par WebKit" : "posée par Void")
        }
        #if os(macOS)
        if let path = item.destination?.path {
            // Makes the Downloads stack in the Dock bounce, like Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
        #else
        // iOS: the file is in Void's folder; now the user picks where it goes.
        if item.asksDestination { DownloadManager.shared.move(item) }
        #endif
        (item.browser ?? .shared).showToast("checkmark.circle", "\(item.filename) téléchargé")
    }

    /// A lost connection: with `resumeData` the download can go on later ("Reprendre").
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = DownloadManager.shared.item(for: download), item.state == .running else { return }
        item.bytesPerSecond = 0
        if let resumeData {
            item.resumeData = resumeData
        } else {
            DownloadManager.shared.discardPartialFile(of: item)
        }
        item.state = .failed(error.localizedDescription)
    }
}

#if os(iOS)
/// Answers the Files picker of "Enregistrer dans…".
private final class FileExporter: NSObject, UIDocumentPickerDelegate {
    let done: ([URL]) -> Void
    init(done: @escaping ([URL]) -> Void) { self.done = done }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done([]) }
}
#endif
