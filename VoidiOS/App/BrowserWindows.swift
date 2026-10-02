import UIKit
import Observation

/// The iOS counterpart of the Mac's window list. There is one screen: it shows either the normal
/// browser (`BrowserModel.shared`, whose session is saved) or private browsing, which has its own
/// model and in-memory storage, both destroyed when private browsing is closed.
@MainActor @Observable
final class BrowserWindows {
    static let shared = BrowserWindows()

    /// The browser on screen: buttons, menus and keyboard shortcuts act on it.
    private(set) var active: BrowserModel = .shared
    /// Private browsing, while it has tabs (or is on screen).
    private(set) var privateBrowser: BrowserModel?
    /// A downloaded file to show in Quick Look over the browser (DownloadManager.open).
    var previewedFile: URL?

    @ObservationIgnored private var sleepTimer: Timer?
    @ObservationIgnored private var started = false

    private init() {}

    var all: [BrowserModel] { [.shared] + (privateBrowser.map { [$0] } ?? []) }

    /// Where links opened from other apps go: never private browsing.
    var normalTarget: BrowserModel { .shared }

    func start() {
        guard !started else { return }
        started = true
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { BrowserWindows.shared.all.forEach { $0.sleepInactiveTabs() } }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BrowserWindows.shared.memoryPressure() }
        }
    }

    /// iOS is about to kill pages (or Void): every tab that isn't shown and can sleep does, now.
    func memoryPressure() {
        NSLog("[Void] mémoire basse : mise en veille des onglets inactifs")
        all.forEach { $0.sleepInactiveTabs(idleFor: 0) }
    }

    // MARK: - Normal and private browsing

    /// Puts `model` on screen.
    func show(_ model: BrowserModel) {
        guard active !== model, all.contains(where: { $0 === model }) else { return }
        let leaving = active
        // The page left behind isn't shown any more: no sound from a browser that isn't there.
        leaving.selectedTab?.webView?.pauseAllMediaPlayback()
        leaving.commandBar = nil
        active = model
        model.selectedTab?.ensureWebView()
        // Private browsing left with nothing open: nothing to come back to.
        if leaving.isPrivate, leaving.allTabs.isEmpty { closePrivate() }
    }

    /// Private browsing (the Mac's ⌘⇧N window). Every tab there is private and shares one
    /// in-memory store.
    @discardableResult
    func openPrivateWindow(url: URL? = nil) -> BrowserModel {
        let model = privateBrowser ?? BrowserModel(kind: .privateWindow)
        if privateBrowser == nil {
            model.openWindowAction = BrowserModel.shared.openWindowAction
            model.openSettingsAction = BrowserModel.shared.openSettingsAction
            privateBrowser = model
        }
        show(model)
        if let url { model.openTab(url: url) }
        return model
    }

    /// Destroys everything private browsing held: pages, cookies, cache, its downloads list.
    func closePrivate() {
        guard let model = privateBrowser else { return }
        if active === model { active = .shared }
        privateBrowser = nil
        model.tearDown()
        BrowserModel.shared.selectedTab?.ensureWebView()
    }
}
