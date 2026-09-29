import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
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
            // Links from other apps never land in a private window.
            for url in urls { BrowserWindows.shared.normalTarget.openExternal(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting stops downloads for good (WebKit keeps no partial file to resume from): ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let running = DownloadManager.shared.activeCount
            #if DEBUG
            if SelfTestRunner.isRequested { return .terminateNow }
            #endif
            guard running > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = running == 1 ? "Un téléchargement est en cours" : "\(running) téléchargements sont en cours"
            alert.informativeText = "Si vous quittez Void maintenant, \(running == 1 ? "il sera interrompu" : "ils seront interrompus")."
            alert.addButton(withTitle: "Continuer les téléchargements")
            alert.addButton(withTitle: "Quitter")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { BrowserModel.shared.saveNow() }
    }
}
