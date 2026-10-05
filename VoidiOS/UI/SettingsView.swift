import SwiftUI
import WebKit

/// Réglages, in a sheet. The Mac's settings minus what only exists there (window layout,
/// extensions, import from other browsers, download folder).
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Apparence") {
                    Picker("Thème", selection: $settings.theme) {
                        ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Couleur") { AccentPicker() }
                    Picker("Les onglets affichent", selection: $settings.tabIconStyle) {
                        ForEach(TabIconStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Progression de lecture dans la barre d'adresse", isOn: $settings.showReadingProgress)
                }

                Section {
                    Picker("Moteur de recherche", selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                    if settings.searchEngine == .custom {
                        TextField("https://exemple.com/search?q=%s", text: $settings.customSearchTemplate)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Recherche")
                } footer: {
                    if settings.searchEngine == .custom { Text("%s est remplacé par la recherche.") }
                }

                Section {
                    Toggle("Rouvrir les onglets au lancement", isOn: $settings.restoreTabs)
                    Toggle("Mettre en veille les onglets inutilisés", isOn: $settings.sleepInactiveTabs)
                    NavigationLink("Espaces") { SpacesSettings() }
                } header: {
                    Text("Onglets")
                } footer: {
                    Text("Un onglet inutilisé depuis 30 minutes libère sa mémoire ; il revient à la même position quand vous y retournez.")
                }

                Section("Vidéo") {
                    Toggle("Empêcher la lecture automatique avec le son", isOn: $settings.blockAutoplayWithSound)
                    Toggle("Picture in Picture automatique en quittant un onglet", isOn: $settings.autoPiP)
                }

                Section("Confidentialité") {
                    NavigationLink("Bloqueur et données de navigation") { PrivacySettings() }
                    NavigationLink("Mots de passe") { PasswordsSettings() }
                    NavigationLink("Téléchargements") { DownloadsSettings() }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                } footer: {
                    Text("Void s'appuie sur WebKit, le moteur du système.")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
}

struct AccentPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentChoice.allCases) { choice in
                Button { settings.accent = choice } label: {
                    Circle()
                        .fill(Theme.swatch(choice))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Theme.primaryText, lineWidth: settings.accent == choice ? 2 : 0).padding(-4))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(settings.accent == choice ? .isSelected : [])
            }
        }
    }
}

// MARK: - Spaces

private struct SpacesSettings: View {
    private var browser: BrowserModel { .shared }
    @State private var pendingDeletion: Space?

    var body: some View {
        List {
            Section {
                ForEach(browser.spaces) { space in
                    SpaceSettingsRow(space: space)
                        .swipeActions(edge: .trailing) {
                            if browser.spaces.count > 1 {
                                Button { pendingDeletion = space } label: { Label("Supprimer", systemImage: "trash") }
                                    .tint(Theme.danger)
                            }
                        }
                }
                .onMove { browser.moveSpace(from: $0, to: $1) }
                Button { browser.addSpace(name: "", icon: Space.iconChoices[browser.spaces.count % Space.iconChoices.count]) } label: {
                    Label("Nouvel espace", systemImage: "plus")
                }
            } footer: {
                Text("Chaque espace a ses onglets et son propre stockage : cookies et sessions ne passent pas de l'un à l'autre.")
            }
        }
        .navigationTitle("Espaces")
        .toolbar { EditButton() }
        .confirmationDialog("Supprimer l'espace « \(pendingDeletion?.name ?? "") » ?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingDeletion) { space in
            Button("Supprimer", role: .destructive) { browser.deleteSpace(space) }
        } message: { _ in
            Text("Ses onglets et ses données de sites (cookies, sessions) sont supprimés.")
        }
    }
}

private struct SpaceSettingsRow: View {
    @Bindable var space: Space

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Space.iconChoices, id: \.self) { icon in
                    Button {
                        space.icon = icon
                        BrowserModel.shared.setNeedsSave()
                    } label: { Label(icon == space.icon ? "Actuelle" : " ", systemImage: icon) }
                }
            } label: {
                Image(systemName: space.icon)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentSoft))
            }
            .accessibilityLabel("Icône de l'espace")
            TextField("Nom", text: $space.name)
                .onSubmit { BrowserModel.shared.setNeedsSave() }
                .onChange(of: space.name) { BrowserModel.shared.setNeedsSave() }
            Text("\(space.allTabs.count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Privacy

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
            Section {
                Toggle("Bloquer les publicités et les traqueurs", isOn: $settings.adBlockEnabled)
                ForEach(settings.adBlockAllowlist, id: \.self) { host in
                    LabeledContent(host) {
                        Button("Réactiver") { settings.toggleAdBlock(for: host) }.buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Bloqueur de publicités")
            } footer: {
                Text(settings.adBlockAllowlist.isEmpty
                     ? "Menu ··· → « Désactiver le bloqueur sur ce site » pour faire une exception."
                     : "Le bloqueur est désactivé sur ces sites.")
            }

            Section {
                if hidden.isEmpty {
                    Text("Aucun élément masqué").foregroundStyle(.secondary)
                }
                ForEach(hidden.keys.sorted(), id: \.self) { host in
                    LabeledContent {
                        Button("Réinitialiser") {
                            ElementHider.shared.reset(host: host)
                            hidden = ElementHider.shared.rules
                        }
                        .buttonStyle(.borderless)
                    } label: {
                        Text(host)
                        Text("\(hidden[host]?.count ?? 0) élément(s)")
                    }
                }
            } header: {
                Text("Éléments masqués")
            } footer: {
                Text("Menu ··· → « Masquer un élément… », puis touchez une bannière ou un bloc : il reste masqué aux visites suivantes.")
            }

            Section {
                Picker("Conserver l'historique", selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { Text($0.label).tag($0) }
                }
                Button(cleared ? "Données effacées" : "Effacer l'historique et les données de sites…", role: .destructive) {
                    confirmingClear = true
                }
                .disabled(cleared)
                .confirmationDialog("Effacer les données de navigation ?", isPresented: $confirmingClear, titleVisibility: .visible) {
                    Button("Effacer", role: .destructive) { clearBrowsingData() }
                } message: {
                    Text("L'historique, les cookies, les caches et les sessions de tous les espaces sont effacés : vous serez déconnecté des sites. Les favoris et les mots de passe sont conservés.")
                }
            } header: {
                Text("Données de navigation")
            }
        }
        .navigationTitle("Confidentialité")
    }
}

// MARK: - Passwords

private struct PasswordsSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var unlocked = false
    @State private var logins: [SavedLogin] = []
    @State private var revealed: [String: String] = [:]
    @State private var query = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                // On iOS there is no extension to step aside for: Void, or nothing.
                Toggle("Enregistrer et remplir les mots de passe", isOn: Binding(
                    get: { settings.passwordManager != .other },
                    set: { settings.passwordManager = $0 ? .automatic : .other }))
            } footer: {
                Text("Désactivez cette option si vous utilisez un autre gestionnaire : le remplissage automatique d'iOS (Mots de passe, Proton Pass, 1Password…) reste proposé au-dessus du clavier.")
            }

            Section {
                Toggle("Remplissage automatique des formulaires", isOn: $settings.formAutofillEnabled)
                Button("Effacer les données de formulaires") { FormAutofill.shared.clear() }
            } footer: {
                Text("Propose les noms, adresses, e-mails… déjà saisis dans des champs de même nom. Rien n'est retenu en navigation privée.")
            }

            Section {
                if !unlocked {
                    Button {
                        Task {
                            if await BiometricGate.authenticate(reason: "afficher vos mots de passe", reuseRecent: false) {
                                logins = KeychainStore.logins()
                                unlocked = true
                            }
                        }
                    } label: { Label("Afficher les mots de passe", systemImage: "faceid") }
                } else {
                    if logins.isEmpty { Text("Aucun mot de passe enregistré.").foregroundStyle(.secondary) }
                    ForEach(filtered) { login in
                        Button { reveal(login) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(login.host).fontWeight(.medium).foregroundStyle(Theme.primaryText)
                                    Text(login.account.isEmpty ? "(sans identifiant)" : login.account).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let password = revealed[login.id] {
                                    Text(password).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.primaryText)
                                } else {
                                    Text("••••••••").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contextMenu {
                            Button { copy(login) } label: { Label("Copier le mot de passe", systemImage: "doc.on.doc") }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                KeychainStore.delete(login)
                                logins = KeychainStore.logins()
                            } label: { Label("Supprimer", systemImage: "trash") }
                            .tint(Theme.danger)
                        }
                    }
                }
            } header: {
                Text("Mots de passe enregistrés")
            } footer: {
                Text("Stockés dans le trousseau de l'appareil, jamais depuis la navigation privée. Touchez pour afficher, touchez longuement pour copier.")
            }
        }
        .navigationTitle("Mots de passe")
        .searchable(text: $query, prompt: "Rechercher")
        // Locked again when the screen goes or Void goes to the background: shown passwords don't stay on screen.
        .onDisappear(perform: lock)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in lock() }
    }

    private var filtered: [SavedLogin] {
        query.isEmpty ? logins : logins.filter { $0.host.localizedCaseInsensitiveContains(query) || $0.account.localizedCaseInsensitiveContains(query) }
    }

    private func lock() {
        unlocked = false
        revealed = [:]
        logins = []
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
            Clipboard.copy(password)
        }
    }
}

// MARK: - Downloads

private struct DownloadsSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var allowed = DownloadPermission.allowedHosts

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Demander où enregistrer", isOn: $settings.askDownloadLocation)
            } footer: {
                Text("Une fois le fichier téléchargé, Void propose de le ranger ailleurs dans Fichiers (iCloud Drive, un autre dossier…). Sinon il reste dans le dossier Void ; un appui long sur un téléchargement → « Enregistrer dans… » le range ailleurs.")
            }
            Section {
                if allowed.isEmpty { Text("Aucun site").foregroundStyle(.secondary) }
                ForEach(allowed, id: \.self) { host in
                    LabeledContent(host) {
                        Button("Retirer") {
                            DownloadPermission.revoke(host)
                            allowed = DownloadPermission.allowedHosts
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Sites autorisés à télécharger")
            } footer: {
                Text("Chaque site demande la première fois.")
            }
            Section {
                Button("Effacer la liste des téléchargements") { DownloadManager.shared.clearFinished() }
            }
        }
        .navigationTitle("Téléchargements")
    }
}
