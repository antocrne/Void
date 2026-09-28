import SwiftUI

enum WindowID {
    static let main = "main"
    static let library = "library"
}

@main
struct VoidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var browser = BrowserModel.shared
    @State private var settings = AppSettings.shared

    var body: some Scene {
        Window("Void", id: WindowID.main) {
            BrowserWindowView()
                .environment(browser)
                .environment(settings)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { VoidCommands(windows: BrowserWindows.shared, settings: settings) }

        Window("Bibliothèque", id: WindowID.library) {
            LibraryView()
                .environment(browser)
                .environment(settings)
        }
        .defaultSize(width: 760, height: 540)

        Settings {
            SettingsView()
                .environment(browser)
                .environment(settings)
        }
    }
}
