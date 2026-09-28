import AppKit
import WebKit
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

    func adopt(_ download: WKDownload, from url: URL?, in browser: BrowserModel?) {
        let item = DownloadItem(filename: url?.lastPathComponent ?? "Téléchargement", sourceURL: url, browser: browser)
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { item?.progress = value }
        }
        items.insert(item, at: 0)
        download.delegate = delegate
        (browser ?? .shared).showToast("arrow.down.circle", "Téléchargement de \(item.filename)")
    }

    func item(for download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel { _ in }
        item.state = .cancelled
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.open(url)
    }

    func clearFinished() {
        items.removeAll { $0.state != .running && !$0.isPrivate }
    }

    /// A private window closed: cancel what's still running and forget its list.
    func forget(browser: BrowserModel) {
        for item in items(of: browser) where item.state == .running { cancel(item) }
        items.removeAll { $0.browser === browser || ($0.isPrivate && $0.browser == nil) }
    }

    static func uniqueDestination(for filename: String) -> URL {
        let folder = AppSettings.shared.downloadFolder
        let safe = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = folder.appendingPathComponent(safe.isEmpty ? "Téléchargement" : safe)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
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
            if let path = item.destination?.path {
                // Makes the Downloads stack in the Dock bounce, like Safari.
                DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
            }
            (item.browser ?? .shared).showToast("checkmark.circle", "\(item.filename) téléchargé")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            guard let item = DownloadManager.shared.item(for: download), item.state == .running else { return }
            item.state = .failed(error.localizedDescription)
        }
    }
}
