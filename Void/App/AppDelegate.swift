import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if SingleInstance.isDuplicate { SingleInstance.startDuplicate() }
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
