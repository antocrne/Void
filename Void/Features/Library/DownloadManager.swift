import Foundation
import WebKit
#if os(macOS)
import AppKit
#endif
import Observation

@MainActor @Observable
final class DownloadItem: Identifiable {
    enum State: Equatable { case running, finished, failed(String), cancelled }

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
    /// Bytes received so far, and the file's size when the server gives it (0 otherwise).
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// Current speed, smoothed over the last seconds (0 until a first measure).
    var bytesPerSecond: Double = 0
    @ObservationIgnored private var lastSample: (date: Date, bytes: Int64)?

    /// Reads a progress report from WebKit. The speed is measured at most twice a second.
    func update(received: Int64, total: Int64) {
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

    /// "12,4 Mo sur 80 Mo · 3,1 Mo/s · 18 s restantes", as much as is known.
    var statusText: String {
        let size = ByteCountFormatter()
        size.countStyle = .file
        var parts = [totalBytes > 0 ? "\(size.string(fromByteCount: receivedBytes)) sur \(size.string(fromByteCount: totalBytes))"
                                    : size.string(fromByteCount: receivedBytes)]
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

/// Downloads go straight to the download folder (Settings → Téléchargements, ~/Downloads by
/// default; unique names), with progress in the Library. Downloads of a private window are only
/// shown in that window and forgotten when it closes (the file itself stays in the folder).
@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()
    private(set) var items: [DownloadItem] = []
    @ObservationIgnored private let delegate = DownloadDelegate()

    var activeCount: Int { items.filter { $0.state == .running }.count }

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

    func adopt(_ download: WKDownload, from url: URL?, in browser: BrowserModel?) {
        let item = DownloadItem(filename: url?.lastPathComponent ?? "Téléchargement", sourceURL: url, browser: browser)
        item.download = download
        item.observation = download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak item] progress, _ in
            let (received, total) = (progress.completedUnitCount, progress.totalUnitCount)
            DispatchQueue.main.async { item?.update(received: received, total: total) }
        }
        items.insert(item, at: 0)
        download.delegate = delegate
        (browser ?? .shared).showToast("arrow.down.circle", "Téléchargement de \(item.filename)")
    }

    func item(for download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel { _ in }
        DownloadManager.release(item.destination)
        item.state = .cancelled
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
    #else
    func reveal(_ item: DownloadItem) { open(item) }

    /// Quick Look, over the browser.
    func open(_ item: DownloadItem) {
        guard item.state == .finished, let url = item.destination, FileManager.default.fileExists(atPath: url.path) else { return }
        BrowserWindows.shared.previewedFile = url
    }
    #endif

    func clearFinished() {
        items.removeAll { $0.state != .running && !$0.isPrivate }
    }

    /// A private window closed: cancel what's still running and forget its list.
    func forget(browser: BrowserModel) {
        for item in items(of: browser) where item.state == .running { cancel(item) }
        items.removeAll { $0.browser === browser || ($0.isPrivate && $0.browser == nil) }
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

private final class DownloadDelegate: NSObject, WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        await MainActor.run {
            let destination = DownloadManager.uniqueDestination(for: suggestedFilename)
            if let item = DownloadManager.shared.item(for: download) {
                item.filename = destination.lastPathComponent
                item.destination = destination
            }
            return destination
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            guard let item = DownloadManager.shared.item(for: download) else { return }
            item.state = .finished
            item.progress = 1
            if let progress = item.download?.progress { item.receivedBytes = max(item.receivedBytes, progress.completedUnitCount) }
            item.bytesPerSecond = 0
            DownloadManager.release(item.destination)
            if let destination = item.destination {
                let already = DownloadManager.quarantine(destination, source: item.sourceURL)
                NSLog("[Void] téléchargement terminé, quarantaine %@", already ? "déjà posée par WebKit" : "posée par Void")
            }
            #if os(macOS)
            if let path = item.destination?.path {
                // Makes the Downloads stack in the Dock bounce, like Safari.
                DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
            }
            #endif
            (item.browser ?? .shared).showToast("checkmark.circle", "\(item.filename) téléchargé")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            guard let item = DownloadManager.shared.item(for: download), item.state == .running else { return }
            DownloadManager.release(item.destination)
            item.state = .failed(error.localizedDescription)
        }
    }
}
