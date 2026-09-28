import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct SettingsView: View {
    @AppStorage("settingsPanel") private var panel = "general"

    var body: some View {
        TabView(selection: $panel) {
            GeneralSettings().tabItem { Label("Général", systemImage: "gearshape") }.tag("general")
            TabsSettings().tabItem { Label("Onglets", systemImage: "sidebar.left") }.tag("tabs")
            ExtensionsSettings().tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }.tag("extensions")
            PasswordsSettings().tabItem { Label("Mots de passe", systemImage: "key") }.tag("passwords")
            DownloadsSettings().tabItem { Label("Téléchargements", systemImage: "arrow.down.circle") }.tag("downloads")
            PrivacySettings().tabItem { Label("Confidentialité", systemImage: "hand.raised") }.tag("privacy")
            AboutSettings().tabItem { Label("À propos", systemImage: "info.circle") }.tag("about")
        }
        .toggleStyle(AccentSwitchStyle())
        .tint(Theme.accent)
        .frame(width: 660)
        .frame(minHeight: 440)
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var isDefault = DefaultBrowser.isDefault

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Navigateur par défaut") {
                    if isDefault {
                        Label("Void est votre navigateur par défaut", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    } else {
                        Button("Définir Void par défaut") {
                            DefaultBrowser.makeDefault { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isDefault = DefaultBrowser.isDefault }
                            }
                        }
                    }
                }
            }
            Section {
                Picker("Thème", selection: $settings.theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Couleur") { AccentPicker() }
                Toggle("Rouvrir les onglets au lancement", isOn: $settings.restoreTabs)
            }
            Section {
                Picker("Moteur de recherche", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                if settings.searchEngine == .custom {
                    LabeledContent("Modèle d'URL (%s = recherche)") {
                        TextField("", text: $settings.customSearchTemplate, prompt: Text("https://…?q=%s"))
                            .voidTextField()
                    }
                }
            }
            Section("Vidéo") {
                Toggle("Picture in Picture automatique en quittant un onglet", isOn: $settings.autoPiP)
                Text("Quand une vidéo joue avec le son et que vous changez d'onglet ou d'espace, elle passe en PiP ; elle revient à son retour. ⌘⇧P bascule le PiP à la main.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ImportSection()
        }
        .formStyle(.grouped)
    }
}

/// Five swatches; the choice applies at once everywhere the accent appears.
private struct AccentPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AccentChoice.allCases) { choice in
                let selected = settings.accent == choice
                Button { withAnimation(Theme.quick) { settings.accent = choice } } label: {
                    Circle()
                        .fill(Theme.swatch(choice))
                        .frame(width: 18, height: 18)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.surface)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Theme.swatch(choice) : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(choice.label)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Text(settings.accent.label).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
        }
    }
}

private struct TabsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Disposition") {
                Toggle("Onglets dans une barre latérale", isOn: Binding(
                    get: { settings.tabLayout == .sidebar },
                    set: { value in withAnimation(Theme.spring) { settings.tabLayout = value ? .sidebar : .top } }))
                Text("À gauche plutôt qu'en haut. Tirez le bord de la barre pour l'élargir ; un double-clic sur ce bord lui rend sa largeur par défaut.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Masquer la barre latérale jusqu'à ce que le pointeur touche le bord", isOn: Binding(
                    get: { settings.sidebarAutoHide },
                    set: { value in
                        withAnimation(Theme.spring) {
                            settings.sidebarAutoHide = value
                            if value { settings.sidebarVisible = true }
                        }
                    }))
                    .disabled(settings.tabLayout != .sidebar)
                Text(settings.tabLayout == .sidebar
                     ? "La page occupe toute la fenêtre ; poussez le pointeur contre le bord gauche pour faire apparaître les onglets. ⌘S garde les onglets masqués ou les réaffiche."
                     : "Disponible avec les onglets dans une barre latérale.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Affichage") {
                Picker("Les onglets affichent", selection: $settings.tabIconStyle) {
                    ForEach(TabIconStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("À côté du titre et sur les onglets épinglés : l'initiale du site sur une pastille, ou l'icône du site.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Afficher la barre de favoris", isOn: $settings.showBookmarksBar.animation(Theme.spring))
                Text("Une rangée au-dessus de la page ; les dossiers s'ouvrent sous forme de menus. Elle se replie avec les onglets.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Afficher la progression de lecture", isOn: $settings.showReadingProgress)
                Text("L'onglet actif se remplit peu à peu quand vous faites défiler la page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mémoire") {
                Toggle("Mettre en veille les onglets inutilisés", isOn: $settings.sleepInactiveTabs)
                Text("Après 30 minutes d'inactivité, un onglet se met en veille et revient à l'endroit où vous l'avez laissé. Restent éveillés : les onglets épinglés, ceux qui jouent du son, ceux en appel et ceux où vous avez saisi du texte.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SpacesSection()
        }
        .formStyle(.grouped)
    }
}

/// Settings → Onglets → Espaces: the main window's sets of tabs.
private struct SpacesSection: View {
    @Environment(BrowserModel.self) private var browser
    @State private var pendingDeletion: Space?

    var body: some View {
        Section {
            ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                SpaceSettingsRow(space: space, index: index, count: browser.spaces.count) { pendingDeletion = space }
            }
            Button {
                browser.addSpace(name: "", icon: "circle")
            } label: {
                Label("Ajouter un espace", systemImage: "plus")
            }
        } header: {
            Text("Espaces")
        } footer: {
            Text("Chaque espace a ses propres onglets, ses onglets épinglés et son propre stockage : cookies et sessions ne sont pas partagés. Les fenêtres privées n'ont pas d'espaces.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Supprimer l'espace « \(pendingDeletion?.name ?? "") » ?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { space in
            Button("Supprimer l'espace et ses données", role: .destructive) { browser.deleteSpace(space) }
        } message: { _ in
            Text("Ses onglets sont fermés et ses données de sites (cookies, sessions, cache) sont effacées.")
        }
    }
}

private struct SpaceSettingsRow: View {
    @Bindable var space: Space
    let index: Int
    let count: Int
    let delete: () -> Void
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Space.iconChoices, id: \.self) { icon in
                    Button { space.icon = icon; browser.setNeedsSave() } label: { Label(icon, systemImage: icon) }
                }
            } label: {
                Image(systemName: space.icon).foregroundStyle(Theme.accent)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Icône")
            TextField("", text: $space.name, prompt: Text("Nom"))
                .voidTextField()
                .onChange(of: space.name) { browser.setNeedsSave() }
            Text("\(space.allTabs.count) onglet(s)")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            Button { browser.moveSpace(from: [index], to: index - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Monter")
            Button { browser.moveSpace(from: [index], to: index + 2) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1)
                .help("Descendre")
            Button(action: delete) { Image(systemName: "trash") }
                .disabled(count < 2)
                .help("Supprimer l'espace")
        }
        .buttonStyle(.borderless)
    }
}

private struct DownloadsSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let folder = settings.downloadFolder
        Form {
            Section {
                LabeledContent("Enregistrer dans") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 16, height: 16)
                        Text(FileManager.default.displayName(atPath: folder.path))
                        Button("Choisir…", action: chooseFolder)
                    }
                }
                HStack {
                    Button("Ouvrir le dossier") { NSWorkspace.shared.open(folder) }
                    if settings.downloadFolderPath != nil {
                        Button("Revenir au dossier Téléchargements") { settings.downloadFolderPath = nil }
                    }
                }
            }
            Section("Historique des téléchargements") {
                LabeledContent("Éléments listés", value: "\(DownloadManager.shared.history.count)")
                HStack {
                    Button("Afficher (⌥⌘L)") { browser.showLibrary(.downloads) }
                    Button("Effacer la liste") { DownloadManager.shared.clearFinished() }
                }
                Text("Les téléchargements d'une fenêtre privée n'y sont jamais ajoutés : ils ne sont visibles que dans cette fenêtre, jusqu'à sa fermeture. Les fichiers, eux, restent dans le dossier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.downloadFolder
        panel.prompt = "Choisir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.downloadFolderPath = url.path
    }
}

private struct AboutSettings: View {
    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let webKit = Bundle(identifier: "com.apple.WebKit")?.infoDictionary?["CFBundleVersion"] as? String
        VStack(spacing: 12) {
            Spacer()
            VoidLogo(size: 72)
            Text("Void").font(.system(size: 24, weight: .bold))
            Text("Un navigateur qui s'efface.").foregroundStyle(.secondary)
            Text("Version \(version) (\(build))" + (webKit.map { " · WebKit \($0)" } ?? ""))
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Afficher les données de Void dans le Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([StateStore.directory])
            }
            Text("Session, historique, favoris et extensions sont dans ~/Library/Application Support/Void. Les mots de passe sont dans le trousseau macOS.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

private struct PrivacySettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var hidden = ElementHider.shared.rules
    @State private var cleared = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Bloqueur de publicités") {
                Toggle("Bloquer les publicités et les traqueurs", isOn: $settings.adBlockEnabled)
                Text("Règles WebKit compilées (WKContentRuleList) : les requêtes sont bloquées avant chargement, sans script dans les pages.")
                    .font(.caption).foregroundStyle(.secondary)
                if !settings.adBlockAllowlist.isEmpty {
                    ForEach(settings.adBlockAllowlist, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button("Réactiver") { settings.toggleAdBlock(for: host) }
                        }
                    }
                }
            }
            Section("Éléments masqués (⌘⇧H)") {
                if hidden.isEmpty {
                    Text("Aucun élément masqué.").foregroundStyle(.secondary)
                }
                ForEach(hidden.keys.sorted(), id: \.self) { host in
                    HStack {
                        Text(host)
                        Text("\(hidden[host]?.count ?? 0) élément(s)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Réinitialiser") { ElementHider.shared.reset(host: host); hidden = ElementHider.shared.rules }
                    }
                }
            }
            Section("Données de navigation") {
                Button(cleared ? "Données effacées" : "Effacer cookies, caches et historique…") {
                    HistoryStore.shared.clear()
                    for space in BrowserModel.shared.spaces {
                        space.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
                    }
                    cleared = true
                }
                .disabled(cleared)
                Text("Les fenêtres privées (⌘⇧N) utilisent un stockage éphémère propre à chaque fenêtre, qui disparaît à sa fermeture.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PasswordsSettings: View {
    @State private var unlocked = false
    @State private var logins: [SavedLogin] = []
    @State private var revealed: [String: String] = [:]
    @State private var query = ""

    var body: some View {
        VStack(spacing: 12) {
            if !unlocked {
                Spacer()
                Image(systemName: "touchid").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
                Text("Les mots de passe sont stockés dans le trousseau macOS. Ils ne sont jamais enregistrés depuis une fenêtre privée.").foregroundStyle(.secondary)
                Button("Déverrouiller avec Touch ID") {
                    Task {
                        if await BiometricGate.authenticate(reason: "afficher vos mots de passe") {
                            logins = KeychainStore.logins()
                            unlocked = true
                        }
                    }
                }
                .voidPrimaryButton()
                Spacer()
            } else {
                TextField("Rechercher", text: $query).voidTextField()
                List(filtered) { login in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(login.host).fontWeight(.medium)
                            Text(login.account.isEmpty ? "(sans identifiant)" : login.account).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let password = revealed[login.id] {
                            Text(password).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        } else {
                            Text("••••••••").foregroundStyle(.secondary)
                        }
                        Button { reveal(login) } label: { Image(systemName: revealed[login.id] == nil ? "eye" : "eye.slash") }
                            .buttonStyle(.borderless)
                        Button { copy(login) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copier le mot de passe")
                    }
                    .contextMenu {
                        Button("Supprimer", role: .destructive) {
                            KeychainStore.delete(login)
                            logins = KeychainStore.logins()
                        }
                    }
                }
                .overlay { if logins.isEmpty { Text("Aucun mot de passe enregistré.").foregroundStyle(.secondary) } }
            }
        }
        .padding()
        .frame(minHeight: 360)
    }

    private var filtered: [SavedLogin] {
        query.isEmpty ? logins : logins.filter { $0.host.localizedCaseInsensitiveContains(query) || $0.account.localizedCaseInsensitiveContains(query) }
    }

    private func reveal(_ login: SavedLogin) {
        if revealed[login.id] != nil { revealed[login.id] = nil; return }
        Task {
            guard await BiometricGate.authenticate(reason: "afficher le mot de passe de \(login.host)") else { return }
            revealed[login.id] = KeychainStore.password(host: login.host, account: login.account)
        }
    }

    private func copy(_ login: SavedLogin) {
        Task {
            guard await BiometricGate.authenticate(reason: "copier le mot de passe de \(login.host)"),
                  let password = KeychainStore.password(host: login.host, account: login.account) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(password, forType: .string)
        }
    }
}

/// Settings → Général → Importer.
private struct ImportSection: View {
    @State private var source: SourceBrowser = SourceBrowser.allCases.first { $0.isInstalled } ?? .chrome
    @State private var bookmarks = true
    @State private var history = true
    @State private var passwords = false
    @State private var result: String?
    @State private var working = false

    var body: some View {
        Group {
            Section("Importer depuis un autre navigateur") {
                Picker("Depuis", selection: $source) {
                    ForEach(SourceBrowser.allCases) { browser in
                        Text(browser.name + (browser.isInstalled ? "" : " (introuvable)")).tag(browser)
                    }
                }
                Toggle("Favoris", isOn: $bookmarks)
                Toggle("Historique", isOn: $history)
                Toggle("Mots de passe", isOn: $passwords)
                if passwords && source.isChromium {
                    Text("macOS va demander l'accès à « \(source.safeStorageService ?? "") » : c'est la clé qui chiffre les mots de passe de \(source.name). Ils sont ensuite enregistrés dans votre trousseau.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(working ? "Import…" : "Importer") { runImport() }
                        .disabled(working || !source.isInstalled || !(bookmarks || history || passwords))
                        .voidPrimaryButton()
                }
            }
            Section("Mots de passe depuis un fichier CSV") {
                Text("Pour Firefox, Safari ou un gestionnaire de mots de passe : exportez un CSV puis importez-le ici. Supprimez ensuite le fichier.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Importer un CSV…") { importCSV() }
            }
            if let result {
                Section { Text(result).font(.callout) }
            }
        }
    }

    private func runImport() {
        working = true
        let r = BrowserImporter.run(from: source, bookmarks: bookmarks, history: history, passwords: passwords)
        result = "Importé depuis \(source.name) : " + r.summary
        working = false
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let count = BrowserImporter.importPasswordCSV(url)
        result = "\(count) mots de passe importés dans le trousseau."
    }
}

private struct ExtensionsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            if #available(macOS 15.4, *) {
                Section {
                    Toggle("Activer les extensions web (WKWebExtension)", isOn: $settings.extensionsEnabled)
                    Text("Les extensions s'appliquent aux onglets ouverts après l'activation.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Autoriser dans les fenêtres privées", isOn: $settings.extensionsInPrivate)
                        .disabled(!settings.extensionsEnabled)
                    Text("Désactivé par défaut : une extension peut conserver des données de navigation privée dans son propre stockage. S'applique aux fenêtres privées ouvertes ensuite.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.extensionsEnabled {
                    ExtensionList()
                }
            } else {
                Text("Les extensions web nécessitent macOS 15.4 ou plus récent.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@available(macOS 15.4, *)
private struct ExtensionList: View {
    private var manager: ExtensionManager { .shared }

    var body: some View {
        Section("Installées") {
            ForEach(manager.contexts, id: \.uniqueIdentifier) { context in
                HStack {
                    if let icon = context.webExtension.icon(for: CGSize(width: 20, height: 20)) {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading) {
                        Text(context.webExtension.displayName ?? "Extension")
                        Text(context.webExtension.displayVersion ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Action") { manager.performAction(context) }
                    Button("Retirer", role: .destructive) { manager.uninstall(context) }
                }
            }
            if manager.contexts.isEmpty {
                Text("Aucune extension.").foregroundStyle(.secondary)
            }
            Button("Installer depuis un dossier ou un .zip…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = true
                panel.allowedContentTypes = [.zip, .folder]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                Task { await manager.install(from: url) }
            }
            if let error = manager.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
            }
        }
    }
}
