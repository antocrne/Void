import SwiftUI
import AVFAudio

/// Names the shared model uses to ask for the library (a window on the Mac, a sheet here).
enum WindowID {
    static let main = "main"
    static let library = "library"
}

@main
struct VoidApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserRootView()
                .environment(settings)
                // Links from other apps (Void as default browser, or an "Open in Void" action).
                .onOpenURL { url in
                    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
                    BrowserWindows.shared.normalTarget.openExternal(url)
                }
        }
        .onChange(of: scenePhase) {
            // iOS can end the app at any time once it is in the background: the session is written now.
            if scenePhase != .active { BrowserModel.shared.saveNow() }
        }
        .commands { VoidCommands() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before any web view creates its store: folders of spaces deleted earlier.
        Space.removePendingStores(keeping: Set(BrowserModel.shared.spaces.map(\.id)))
        // Files of downloads the last session didn't finish: iOS may end Void at any time.
        DownloadManager.shared.removeUnfinishedFiles()
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BrowserWindows.shared.start()
        ContentRules.shared.start()
        // A page's sound plays with the ring switch off, and its video can go to Picture in Picture.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        BrowserModel.shared.saveNow()
    }
}

/// Keyboard shortcuts (iPad with a keyboard), the Mac's where they make sense.
struct VoidCommands: Commands {
    private var browser: BrowserModel { BrowserWindows.shared.active }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nouvel onglet") { browser.showCommandBar(.newTab) }.keyboardShortcut("t")
            Button("Navigation privée") { BrowserWindows.shared.openPrivateWindow() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Fermer l'onglet") { browser.closeCurrentTab() }.keyboardShortcut("w")
            Button("Rouvrir l'onglet fermé") { browser.reopenClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandMenu("Page") {
            Button("Barre d'adresse") { browser.showCommandBar(.currentTab) }.keyboardShortcut("l")
            Button("Recharger") { browser.reload() }.keyboardShortcut("r")
            Button("Précédent") { browser.goBack() }.keyboardShortcut("[")
            Button("Suivant") { browser.goForward() }.keyboardShortcut("]")
            Divider()
            Button("Rechercher dans la page") { browser.toggleFind() }.keyboardShortcut("f")
            Button("Mode lecture") { browser.toggleReader() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Masquer un élément") { browser.hideElement() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Picture in Picture") { browser.togglePiP() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Favori") { browser.toggleBookmark() }.keyboardShortcut("d")
            Divider()
            Button("Agrandir") { browser.zoom(0.1) }.keyboardShortcut("+")
            Button("Réduire") { browser.zoom(-0.1) }.keyboardShortcut("-")
            Button("Taille réelle") { browser.zoom(nil) }.keyboardShortcut("0")
        }
        CommandMenu("Onglets") {
            Button("Onglet suivant") { browser.selectAdjacentTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Onglet précédent") { browser.selectAdjacentTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Épingler l'onglet") { if let tab = browser.selectedTab { browser.togglePin(tab) } }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Barre latérale") { browser.toggleSidebar() }.keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Dernier onglet" : "Onglet \(number)") { browser.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Divider()
            Button("Historique") { browser.showLibrary(.history) }.keyboardShortcut("y")
            Button("Favoris") { browser.showLibrary(.bookmarks) }.keyboardShortcut("b", modifiers: [.command, .option])
            Button("Téléchargements") { browser.showLibrary(.downloads) }.keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
