import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppSettings.shared.applyAppearance()
            BrowserWindows.shared.start()
            ContentRules.shared.start()
            if #available(macOS 15.4, *), AppSettings.shared.extensionsEnabled {
                ExtensionManager.shared.loadInstalled()
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

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { BrowserModel.shared.saveNow() }
    }
}
