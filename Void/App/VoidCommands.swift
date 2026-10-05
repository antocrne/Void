import SwiftUI

/// Menu bar + keyboard shortcuts (macOS conventions, Safari-compatible where possible).
/// Every action targets the frontmost browser window.
struct VoidCommands: Commands {
    let windows: BrowserWindows
    let settings: AppSettings

    private var browser: BrowserModel { windows.active }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nouvel onglet") { browser.showCommandBar(.newTab) }
                .keyboardShortcut("t")
            Button("Nouvelle fenêtre") { windows.openNormalWindow() }
                .keyboardShortcut("n")
            Button("Nouvelle fenêtre privée") { windows.openPrivateWindow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Nouvel espace…") { BrowserModel.shared.addSpace(name: "", icon: "circle") }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!browser.managesSpaces)
            Divider()
            Button("Ouvrir l'emplacement…") { browser.showCommandBar(.currentTab) }
                .keyboardShortcut("l")
            Button("Rouvrir l'onglet fermé") { browser.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Fermer l'onglet") { browser.closeTabOrWindow() }
                .keyboardShortcut("w")
            Button("Fermer la fenêtre") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {}

        CommandGroup(replacing: .printItem) {
            Button("Imprimer…") { browser.print() }
                .keyboardShortcut("p")
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Rechercher dans la page…") { browser.toggleFind() }
                .keyboardShortcut("f")
            Button("Occurrence suivante") { browser.findNext(backwards: false) }
                .keyboardShortcut("g")
            Button("Occurrence précédente") { browser.findNext(backwards: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Copier l'adresse de la page") { browser.copyURL() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        CommandGroup(before: .toolbar) {
            Button(settings.sidebarVisible && !settings.sidebarAutoHide ? "Masquer la barre latérale" : "Afficher la barre latérale") { browser.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Toggle("Garder les onglets masqués", isOn: Binding(get: { settings.sidebarAutoHide }, set: { _ in browser.toggleTabsHidden() }))
                .keyboardShortcut("s")
                .disabled(settings.tabLayout != .sidebar)
            Picker("Onglets", selection: Binding(get: { settings.tabLayout }, set: { newValue in withAnimation(Theme.spring) { settings.tabLayout = newValue } })) {
                ForEach(TabLayout.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Button("Recharger la page") { browser.reload() }
                .keyboardShortcut("r")
            Button("Recharger sans le cache") { browser.reload(fromOrigin: true) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Mode lecture") { browser.toggleReader() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Picture in Picture") { browser.togglePiP() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button(browser.shownSplit == nil ? "Afficher côte à côte" : "Quitter la vue côte à côte") { browser.toggleSideBySide() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(browser.selectedTab == nil)
            Button("Passer à l'autre côté") { browser.focusOtherSide() }
                .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                .disabled(browser.shownSplit == nil)
            Button("Inverser les côtés") { browser.swapSides() }
                .disabled(browser.shownSplit == nil)
            Divider()
            Button("Zoom avant") { browser.zoom(0.1) }
                .keyboardShortcut("+")
            Button("Zoom arrière") { browser.zoom(-0.1) }
                .keyboardShortcut("-")
            Button("Taille réelle") { browser.zoom(nil) }
                .keyboardShortcut("0")
            Divider()
        }

        CommandMenu("Historique") {
            Button("Précédent") { browser.goBack() }
                .keyboardShortcut("[")
            Button("Suivant") { browser.goForward() }
                .keyboardShortcut("]")
            Divider()
            Button("Afficher tout l'historique") { browser.showLibrary(.history) }
                .keyboardShortcut("y")
        }

        CommandMenu("Favoris") {
            Button("Ajouter / retirer des favoris") { browser.toggleBookmark() }
                .keyboardShortcut("d")
            Button("Afficher les favoris") { browser.showLibrary(.bookmarks) }
                .keyboardShortcut("b", modifiers: [.command, .option])
        }

        CommandMenu("Outils") {
            Button("Masquer un élément…") { browser.hideElement() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Activer/désactiver le bloqueur sur ce site") { browser.toggleAdBlockForCurrentSite() }
            Button("Téléchargements") { browser.showDownloads() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button(VoidNotes.shared.menuTitle("Envoyer la page vers Void Notes")) { browser.sendPageToNotes() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!VoidNotes.shared.isInstalled)
            Divider()
            Button("Web Inspector") { browser.showInspector(console: false) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Console JavaScript") { browser.showInspector(console: true) }
                .keyboardShortcut("j", modifiers: [.command, .option])
        }

        CommandGroup(before: .windowList) {
            Button("Onglet suivant") { browser.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Onglet précédent") { browser.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Onglet suivant ") { browser.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Onglet précédent ") { browser.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Épingler / désépingler l'onglet") { if let tab = browser.selectedTab { browser.togglePin(tab) } }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(!browser.managesSpaces)
            Divider()
            Button("Espace suivant") { browser.switchSpace(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(browser.isPrivate)
            Button("Espace précédent") { browser.switchSpace(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(browser.isPrivate)
            Divider()
            ForEach(1..<10) { n in
                Button(n == 9 ? "Dernier onglet" : "Onglet \(n)") { browser.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))))
            }
            Divider()
        }
    }
}
