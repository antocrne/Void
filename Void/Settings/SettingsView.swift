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
                LabeledContent("Personnalisation du premier lancement") {
                    Button("Revoir…") {
                        let browser = BrowserModel.shared
                        browser.onboardingStep = 0
                        // Shown over the main window, which may have been closed.
                        if browser.window?.isVisible != true { browser.openWindowAction?(WindowID.main) }
                        browser.window?.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
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
                Toggle("Empêcher la lecture automatique avec le son", isOn: $settings.blockAutoplayWithSound)
                Text("Une vidéo ou un son ne démarre qu'après un clic, sauf en muet. S'applique aux onglets ouverts ensuite.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Picture in Picture automatique en quittant un onglet", isOn: $settings.autoPiP)
                Text("Quand une vidéo joue avec le son et que vous changez d'onglet ou d'espace, elle passe en PiP ; elle revient à son retour. ⌘⇧P bascule le PiP à la main.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Réunion en fenêtre flottante en quittant son onglet", isOn: $settings.autoMeetingPiP)
                Text("Pendant un appel (caméra ou micro utilisés : Meet, Teams, Zoom, Jitsi…), la page entière passe dans une petite fenêtre au-dessus des autres, avec tous les participants et les boutons de l'appel ; elle revient à son retour. ⌘⇧P l'y envoie à la main.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ImportSection()
        }
        .formStyle(.grouped)
    }
}

/// Five swatches; the choice applies at once everywhere the accent appears.
struct AccentPicker: View {
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
        .spaceDeletionDialog(space: pendingDeletion, dismiss: { pendingDeletion = nil }) { browser.deleteSpace($0) }
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
    @State private var allowedHosts = DownloadPermission.allowedHosts

    var body: some View {
        @Bindable var settings = settings
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
                Toggle("Demander où enregistrer chaque fichier", isOn: $settings.askDownloadLocation)
                Text("Un fichier déjà téléchargé se range ailleurs par un clic droit dans la liste des téléchargements → « Déplacer vers… ».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sites autorisés à télécharger") {
                if allowedHosts.isEmpty {
                    Text("Aucun site : chacun demande la première fois.").foregroundStyle(.secondary)
                }
                ForEach(allowedHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button("Retirer") {
                            DownloadPermission.revoke(host)
                            allowedHosts = DownloadPermission.allowedHosts
                        }
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
        .onAppear { allowedHosts = DownloadPermission.allowedHosts }
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
    @State private var confirmingClear = false

    private func clearBrowsingData() {
        HistoryStore.shared.clear()
        DownloadManager.shared.clearFinished()
        FaviconLoader.clearCache()
        for browser in BrowserWindows.shared.all { browser.forgetClosedTabs() }
        for space in BrowserModel.shared.spaces {
            space.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
        cleared = true
    }

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
                Picker("Conserver l'historique", selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { Text($0.label).tag($0) }
                }
                Text("Les pages que vous n'avez pas revisitées depuis plus longtemps sont retirées de l'historique.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(cleared ? "Données effacées" : "Effacer cookies, caches et historique…") { confirmingClear = true }
                    .disabled(cleared)
                    .confirmationDialog("Effacer les données de navigation ?", isPresented: $confirmingClear) {
                        Button("Effacer", role: .destructive) { clearBrowsingData() }
                    } message: {
                        Text("Historique, onglets fermés récemment, liste des téléchargements, cookies et caches de tous les espaces. Vous serez déconnecté de tous les sites. Les favoris, mots de passe et données de formulaires sont conservés.")
                    }
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
    @State private var pendingDeletion: SavedLogin?

    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Gestionnaire de mots de passe", selection: $settings.passwordManager) {
                    ForEach(PasswordManagerChoice.allCases) { Text($0.label).tag($0) }
                }
                Text(managerCaption).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.passwordManager != .void, let app = PasswordManager.shared.installedApp,
                   let id = PasswordManager.shared.missingExtensionID {
                    addExtensionButton(app, id: id)
                }
            }
            HStack {
                Toggle("Remplissage automatique des formulaires", isOn: $settings.formAutofillEnabled)
                Spacer()
                Button("Effacer les données") { FormAutofill.shared.clear() }
            }
            Text("Propose les noms, adresses, e-mails… déjà saisis dans des champs de même nom. Rien n'est retenu en navigation privée.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if !unlocked {
                Spacer()
                Image(systemName: "touchid").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
                Text("Les mots de passe sont stockés dans le trousseau macOS. Ils ne sont jamais enregistrés depuis une fenêtre privée.").foregroundStyle(.secondary)
                Button("Déverrouiller avec Touch ID") {
                    Task {
                        if await BiometricGate.authenticate(reason: "afficher vos mots de passe", reuseRecent: false) {
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
                        Button("Supprimer…", role: .destructive) { pendingDeletion = login }
                    }
                }
                .overlay { if logins.isEmpty { Text("Aucun mot de passe enregistré.").foregroundStyle(.secondary) } }
                .confirmationDialog("Supprimer le mot de passe de « \(pendingDeletion?.host ?? "") » ?",
                                    isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                                    presenting: pendingDeletion) { login in
                    Button("Supprimer", role: .destructive) {
                        KeychainStore.delete(login)
                        logins = KeychainStore.logins()
                    }
                } message: { login in
                    Text("Le compte \(login.account.isEmpty ? "sans identifiant" : "« \(login.account) »") est retiré du trousseau.")
                }
            }
        }
        .padding()
        .frame(minHeight: 360)
        // Locked again when the panel goes or Void goes to the background: shown passwords don't stay on screen.
        .onDisappear(perform: lock)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in lock() }
    }

    private func lock() {
        unlocked = false
        revealed = [:]
        logins = []
    }

    /// The app is on the Mac but only its extension fills passwords in Void.
    @ViewBuilder
    private func addExtensionButton(_ app: PasswordManager.ManagerApp, id: String) -> some View {
        if #available(macOS 15.4, *) {
            // Not created while extensions are off: the button turns them on.
            let extensions = settings.extensionsEnabled ? ExtensionManager.shared : nil
            let installing = extensions?.installing != nil
            HStack {
                Button(installing ? "Ajout de l'extension…" : "Ajouter l'extension \(app.name)") {
                    settings.extensionsEnabled = true
                    Task { await ExtensionManager.shared.installFromWebStore(id) }
                }
                .disabled(installing)
                if let error = extensions?.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
    }

    private var managerCaption: String {
        let manager = PasswordManager.shared
        let other = manager.otherManagerName
        let appOnly = manager.managerExtensionName == nil && manager.installedApp != nil
        switch settings.passwordManager {
        case .automatic:
            if let other, appOnly {
                return "\(other) est installé sur ce Mac, mais sans son extension il ne remplit rien dans Void : Void continue d'enregistrer et de remplir vos mots de passe. Ajoutez son extension pour lui laisser la main."
            }
            return other.map { "\($0) est installé : Void le laisse enregistrer et remplir vos mots de passe." }
                ?? "Void enregistre et remplit vos mots de passe, sauf si l’extension d’un autre gestionnaire est installée dans Void."
        case .void:
            return "Void propose d'enregistrer vos mots de passe dans le trousseau macOS et les remplit."
        case .other:
            return "Void ne propose plus d'enregistrer ni de remplir : votre gestionnaire (extension ou app) s'en charge."
        }
    }

    private var filtered: [SavedLogin] {
        query.isEmpty ? logins : logins.filter { $0.host.localizedCaseInsensitiveContains(query) || $0.account.localizedCaseInsensitiveContains(query) }
    }

    private func reveal(_ login: SavedLogin) {
        if revealed[login.id] != nil { revealed[login.id] = nil; return }
        Task {
            guard await BiometricGate.authenticate(reason: "afficher le mot de passe de \(login.host)", reuseRecent: false) else { return }
            revealed[login.id] = KeychainStore.password(host: login.host, account: login.account)
        }
    }

    private func copy(_ login: SavedLogin) {
        Task {
            guard await BiometricGate.authenticate(reason: "copier le mot de passe de \(login.host)", reuseRecent: false),
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
                    .disabled(working)
            }
            if let result {
                Section { Text(result).font(.callout) }
            }
        }
    }

    private func runImport() {
        working = true
        let source = source
        Task {
            let r = await BrowserImporter.run(from: source, bookmarks: bookmarks, history: history, passwords: passwords)
            result = "Importé depuis \(source.name) : " + r.summary
            working = false
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        Task {
            let count = await Task.detached(priority: .userInitiated) { BrowserImporter.importPasswordCSV(url) }.value
            result = "\(count) mots de passe importés dans le trousseau."
            working = false
        }
    }
}

private struct ExtensionsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            if #available(macOS 15.4, *) {
                Section {
                    CaptionedToggle(title: "Activer les extensions",
                                    caption: "Les extensions Chrome fonctionnent dans Void. Elles s'appliquent aux onglets ouverts ensuite.",
                                    isOn: $settings.extensionsEnabled)
                }
                ExtensionInstall()
                Section {
                    CaptionedToggle(title: "Autoriser dans les fenêtres privées",
                                    caption: "Désactivé par défaut — une fenêtre privée ne garde rien, extensions comprises.",
                                    isOn: $settings.extensionsInPrivate)
                        .disabled(!settings.extensionsEnabled)
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

/// A switch with its title in bold and an explanation under it.
private struct CaptionedToggle: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        // One label (a grouped form would lay out two texts side by side).
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionInstall: View {
    @State private var storeLink = ""
    private var manager: ExtensionManager { .shared }

    var body: some View {
        Section {
            HStack {
                Text("Ajouter depuis le Chrome Web Store").font(.headline)
                Spacer()
                Button("Ouvrir le Store") { manager.openWebStore() }
            }
            HStack {
                TextField("", text: $storeLink, prompt: Text("Coller le lien d'une extension, ou son identifiant"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(installFromStore)
                Button("Ajouter", action: installFromStore)
                    .disabled(storeLink.trimmingCharacters(in: .whitespaces).isEmpty || manager.installing != nil)
            }
            Text("Ou trouvez-la dans le Store et cliquez sur « Ajouter à Void » sur sa page.")
                .font(.caption).foregroundStyle(.secondary)
            if let name = manager.installing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installation : \(name)…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = manager.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        Section {
            HStack {
                Button("Fichier .crx, .zip ou dossier…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "crx") ?? .data]
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    Task { await manager.install(from: url) }
                }
                Menu("Importer depuis…") {
                    let chromium = SourceBrowser.allCases.filter(\.isChromium)
                    let readable = chromium.filter(\.isInstalled)
                    let blocked = chromium.filter(\.isBlocked)
                    if readable.isEmpty && blocked.isEmpty {
                        Text("Aucun navigateur Chrome, Brave, Edge, Arc ou Vivaldi trouvé")
                    }
                    ForEach(readable) { browser in
                        let found = ChromeExtensions.installed(in: browser)
                        Menu(browser.name) {
                            if found.isEmpty { Text("Aucune extension") }
                            ForEach(found) { item in
                                Button(item.name + (manager.isInstalled(chromeID: item.id) ? " ✓" : "")) {
                                    Task { await manager.importExtension(item) }
                                }
                            }
                            if found.count > 1 {
                                Divider()
                                Button("Tout importer") {
                                    Task { for item in found where !manager.isInstalled(chromeID: item.id) { await manager.importExtension(item) } }
                                }
                            }
                        }
                    }
                    ForEach(blocked) { browser in
                        Button("\(browser.name) : accès refusé par macOS…") { SourceBrowser.openFullDiskAccessSettings() }
                    }
                    if !blocked.isEmpty {
                        Text("Autorisez Void dans Accès complet au disque, puis rouvrez ce menu.")
                    }
                    if SourceBrowser.firefox.isInstalled {
                        Divider()
                        // Firefox extensions aren't Chrome ones: most are on the Chrome Web Store too.
                        Button("Firefox : retrouver ses extensions dans le Chrome Web Store") { manager.openWebStore() }
                    }
                }
                .fixedSize()
                .disabled(manager.installing != nil)
            }
        } header: {
            Text("Autres sources")
        }
    }

    private func installFromStore() {
        let link = storeLink
        Task {
            await manager.installFromWebStore(link)
            if manager.lastError == nil { storeLink = "" }
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionList: View {
    private var manager: ExtensionManager { .shared }
    @State private var pendingRemoval: WKWebExtensionContext?

    var body: some View {
        let _ = manager.actionsRevision   // redrawn when one is pinned
        Section("Installées") {
            ForEach(manager.contexts, id: \.uniqueIdentifier) { context in
                HStack {
                    if let icon = context.webExtension.icon(for: CGSize(width: 20, height: 20)) {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading) {
                        Text(context.webExtension.displayName ?? "Extension")
                        Text(context.webExtension.displayVersion ?? "").font(.caption).foregroundStyle(.secondary)
                        if !context.errors.isEmpty {
                            Text(context.errors.map(\.localizedDescription).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                                .help(context.errors.map(\.localizedDescription).joined(separator: "\n"))
                        }
                    }
                    Spacer()
                    Toggle("Épinglée", isOn: Binding(get: { manager.isPinned(context) }, set: { manager.setPinned($0, context) }))
                        .toggleStyle(.checkbox)
                        .help("Afficher son bouton dans la barre, à côté de 🧩")
                    if context.optionsPageURL != nil {
                        Button("Options") { manager.openOptions(context) }
                    }
                    Button("Retirer…", role: .destructive) { pendingRemoval = context }
                }
            }
            .confirmationDialog("Retirer « \(pendingRemoval?.webExtension.displayName ?? "cette extension") » de Void ?",
                                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                                presenting: pendingRemoval) { context in
                Button("Retirer", role: .destructive) { manager.uninstall(context) }
            } message: { _ in
                Text("Ses réglages et ses données sont supprimés.")
            }
            if manager.contexts.isEmpty {
                Text("Aucune extension.").foregroundStyle(.secondary)
            }
        }
    }
}
