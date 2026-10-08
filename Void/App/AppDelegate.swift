import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if SingleInstance.isDuplicate {
                SingleInstance.startDuplicate()
            } else {
                var selfTest = false
                #if DEBUG
                selfTest = SelfTestRunner.isRequested   // its session isn't the user's: left alone
                #endif
                // Before any web view creates its store: folders of spaces deleted earlier.
                if !selfTest {
                    Space.removePendingStores(keeping: Set(BrowserModel.shared.spaces.map(\.id)))
                    // Files of downloads the last session didn't finish (crash).
                    DownloadManager.shared.removeUnfinishedFiles()
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Another Void is running: this one only passes links on (see SingleInstance).
            guard !SingleInstance.isDuplicate else { return }
            AppSettings.shared.applyAppearance()
            BrowserWindows.shared.start()
            ContentRules.shared.start()
            // Copies left by an import that was interrupted (crash, quit).
            BrowserImporter.removeTemporaryCopies()
            if #available(macOS 15.4, *), AppSettings.shared.extensionsEnabled {
                ExtensionManager.shared.start()
            }
            var selfTest = false
            #if DEBUG
            selfTest = SelfTestRunner.isRequested
            SelfTestRunner.startIfRequested()
            #endif
            // First launch: let the user choose how Void looks (Settings → Général can replay it).
            if !AppSettings.shared.onboardingCompleted && !selfTest {
                BrowserModel.shared.onboardingStep = 0
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if SingleInstance.isDuplicate { return SingleInstance.forward(urls) }
            // Links from other apps never land in a private window.
            for url in urls { BrowserWindows.shared.normalTarget.openExternal(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting stops downloads for good, paused ones too (they can't resume after a relaunch), and only the
    /// main window's tabs come back at the next launch: ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            #if DEBUG
            if SelfTestRunner.isRequested { return .terminateNow }
            #endif
            let running = DownloadManager.shared.unfinishedCount
            guard running > 0 else { return keepTabsOfOtherWindows() ? .terminateNow : .terminateCancel }
            let alert = NSAlert()
            alert.messageText = running == 1 ? String(localized: "Un téléchargement est en cours")
                                             : String(localized: "\(running) téléchargements sont en cours")
            alert.informativeText = running == 1
                ? String(localized: "Si vous quittez Void maintenant, il sera interrompu et le fichier incomplet supprimé.")
                : String(localized: "Si vous quittez Void maintenant, ils seront interrompus et les fichiers incomplets supprimés.")
            alert.addButton(withTitle: String(localized: "Continuer les téléchargements"))
            alert.addButton(withTitle: String(localized: "Quitter"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            return keepTabsOfOtherWindows() ? .terminateNow : .terminateCancel
        }
    }

    /// ⌘N windows aren't saved: their tabs would be lost without a word. Returns false to cancel.
    @MainActor
    private func keepTabsOfOtherWindows() -> Bool {
        let main = BrowserModel.shared
        let others = BrowserWindows.shared.all.filter { $0.kind == .secondary }
        let tabs = others.flatMap(\.allTabs).filter { $0.url != nil }
        guard !tabs.isEmpty, AppSettings.shared.restoreTabs else { return true }
        let alert = NSAlert()
        alert.messageText = tabs.count == 1 ? String(localized: "Un onglet d'une autre fenêtre ne sera pas rouvert")
                                            : String(localized: "\(tabs.count) onglets d'autres fenêtres ne seront pas rouverts")
        alert.informativeText = String(localized: "Au prochain lancement, Void ne rouvre que les onglets de la fenêtre principale.")
        alert.addButton(withTitle: String(localized: "Les garder dans la fenêtre principale"))
        alert.addButton(withTitle: String(localized: "Quitter sans eux"))
        alert.addButton(withTitle: String(localized: "Annuler"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            main.adoptForNextLaunch(tabs)
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            BrowserModel.shared.saveNow()
            if !SingleInstance.isDuplicate { DownloadManager.shared.removeUnfinishedFiles() }
            AppLanguage.relaunchIfRequested()
        }
    }
}

/// Links from other apps once the main window is up: taken before SwiftUI sees them, as its window
/// scene would take them too and close and reopen the window at each link. Until then SwiftUI
/// keeps them: the link that launches Void is what makes it open its window.
final class ExternalLinks: NSObject {
    static let shared = ExternalLinks()
    private var active = false

    func takeOver() {
        guard !active else { return }
        active = true
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(open(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func open(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(URL.init(string:)) else { return }
        MainActor.assumeIsolated { BrowserWindows.shared.normalTarget.openExternal(url) }
    }
}
