import SwiftUI

/// Sidebar layout: navigation, address, pinned tabs, the space's tabs, spaces.
struct SidebarView: View {
    @Environment(BrowserModel.self) private var browser
    @Namespace private var selection
    @State private var pinnedReorder = TabReorder(layout: .grid, spacing: 6)

    var body: some View {
        let space = browser.currentSpace
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                Spacer()
                ChromeButton(symbol: "sidebar.left", help: "Masquer la barre latérale (⌃⌘S)") { browser.toggleSidebar() }
                ChromeButton(symbol: "chevron.left", help: "Précédent (⌘[)", disabled: !(browser.selectedTab?.canGoBack ?? false)) { browser.goBack() }
                ChromeButton(symbol: "chevron.right", help: "Suivant (⌘])", disabled: !(browser.selectedTab?.canGoForward ?? false)) { browser.goForward() }
                ChromeButton(symbol: browser.selectedTab?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Recharger (⌘R)") {
                    browser.selectedTab?.isLoading == true ? browser.stopLoading() : browser.reload()
                }
            }
            .frame(height: 30)
            .padding(.top, 4)

            AddressPill()

            if !space.pinned.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(space.pinned) { tab in
                        PinnedTile(tab: tab, selected: space.selectedTabID == tab.id)
                            .tabReorderable(tab, with: pinnedReorder)
                    }
                }
                .coordinateSpace(.named(pinnedReorder.coordinateSpace))
                .transition(.opacity)
            }

            ZStack {
                SpaceTabList(space: space, namespace: selection)
                    .id(space.id)
                    .transition(.push(from: browser.spaceTransitionEdge))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()

            SpaceBar()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .background(SpaceSwipeCatcher { browser.switchSpace(by: $0) })
    }
}

private struct SpaceTabList: View {
    let space: Space
    let namespace: Namespace.ID
    @Environment(BrowserModel.self) private var browser
    @State private var hoveringNew = false
    @State private var reorder = TabReorder(layout: .vertical, spacing: 2)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if browser.isPrivate {
                    PrivateBadge()
                    Text("Rien n'est conservé").font(.system(size: 11, weight: .medium))
                } else {
                    Image(systemName: space.icon).font(.system(size: 11, weight: .semibold))
                    Text(space.name).font(.system(size: 11.5, weight: .semibold))
                }
                Spacer()
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.bottom, 4)

            Button { browser.showCommandBar(.newTab) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 16)
                    Text("Nouvel onglet").font(.system(size: 12.5))
                    Spacer()
                    Text("⌘T").font(.system(size: 11)).foregroundStyle(Theme.secondaryText.opacity(hoveringNew ? 1 : 0))
                }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hoveringNew ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringNew = $0 }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(space.tabs) { tab in
                        SidebarTabRow(tab: tab, selected: space.selectedTabID == tab.id, namespace: namespace)
                            .tabReorderable(tab, with: reorder)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .coordinateSpace(.named(reorder.coordinateSpace))
            }
        }
    }
}

/// Bottom of the sidebar: downloads, extensions, private window, spaces (none in a private window).
private struct SpaceBar: View {
    @Environment(BrowserModel.self) private var browser
    @State private var creating = false

    var body: some View {
        HStack(spacing: 2) {
            DownloadsButton()
            ExtensionsButton()
            if browser.isPrivate {
                Spacer()
                ChromeButton(symbol: "xmark.circle", help: "Fermer la fenêtre privée et tout effacer (⌘⇧W)") { browser.window?.performClose(nil) }
            } else {
                ChromeButton(symbol: "eye.slash", help: "Nouvelle fenêtre privée (⌘⇧N)") { BrowserWindows.shared.openPrivateWindow() }
                Spacer()
                ForEach(browser.spaces) { space in
                    SpaceIconButton(space: space, selected: space.id == browser.currentSpaceID)
                }
                if browser.managesSpaces {
                    ChromeButton(symbol: "plus", help: "Nouvel espace") { creating = true }
                        .popover(isPresented: $creating, arrowEdge: .top) { NewSpaceForm { creating = false } }
                }
            }
        }
        .frame(height: 30)
    }
}

struct SpaceIconButton: View {
    let space: Space
    let selected: Bool
    @Environment(BrowserModel.self) private var browser
    @State private var renaming = false

    var body: some View {
        ChromeButton(symbol: space.icon, help: space.name, active: selected) {
            browser.switchSpace(to: space)
        }
        .symbolVariant(selected ? .fill : .none)
        .contextMenu {
            if browser.managesSpaces { spaceMenu }
        }
        .popover(isPresented: $renaming) {
            RenameSpaceForm(space: space) { renaming = false }
        }
    }

    @ViewBuilder private var spaceMenu: some View {
        Button("Renommer…") { renaming = true }
        Menu("Icône") {
            ForEach(Space.iconChoices, id: \.self) { icon in
                Button { space.icon = icon; browser.setNeedsSave() } label: { Label(icon, systemImage: icon) }
            }
        }
        Divider()
        Button("Supprimer l'espace", role: .destructive) { browser.deleteSpace(space) }
            .disabled(browser.spaces.count < 2)
    }
}

struct NewSpaceForm: View {
    let done: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var name = ""
    @State private var icon = "circle"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nouvel espace").font(.headline)
            TextField("Nom (Travail, Maison…)", text: $name)
                .voidTextField()
                .onSubmit(create)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 8), spacing: 6) {
                ForEach(Space.iconChoices, id: \.self) { symbol in
                    Button { icon = symbol } label: {
                        Image(systemName: symbol)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(icon == symbol ? Theme.accentSoft : .clear))
                            .foregroundStyle(icon == symbol ? Theme.accent : Theme.primaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Chaque espace a son propre stockage : cookies et sessions ne sont pas partagés.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler", action: done)
                Button("Créer", action: create).keyboardShortcut(.defaultAction).voidPrimaryButton()
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func create() {
        browser.addSpace(name: name, icon: icon)
        done()
    }
}

private struct RenameSpaceForm: View {
    let space: Space
    let done: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var name = ""

    var body: some View {
        HStack {
            TextField("Nom", text: $name).voidTextField().frame(width: 180)
                .onSubmit(save)
            Button("OK", action: save).keyboardShortcut(.defaultAction).voidPrimaryButton()
        }
        .padding(12)
        .onAppear { name = space.name }
    }

    private func save() {
        if !name.isEmpty { space.name = name; browser.setNeedsSave() }
        done()
    }
}

/// Opens the downloads history — or, in a private window, the list of that window's downloads,
/// which is never added to the history.
struct DownloadsButton: View {
    @Environment(BrowserModel.self) private var browser
    @State private var showingPrivateList = false

    var body: some View {
        let active = DownloadManager.shared.activeCount(for: browser)
        ChromeButton(symbol: active > 0 ? "arrow.down.circle.fill" : "arrow.down.circle", help: "Téléchargements (⌥⌘L)", active: active > 0) {
            if browser.isPrivate { showingPrivateList = true } else { browser.showLibrary(.downloads) }
        }
        .popover(isPresented: $showingPrivateList, arrowEdge: .top) {
            PrivateDownloadsList(browser: browser)
        }
    }
}

private struct PrivateDownloadsList: View {
    let browser: BrowserModel

    var body: some View {
        let items = DownloadManager.shared.items(of: browser)
        VStack(alignment: .leading, spacing: 8) {
            Text("Téléchargements de cette fenêtre").font(.headline)
            if items.isEmpty {
                Text("Aucun téléchargement.").foregroundStyle(.secondary)
            } else {
                ForEach(items) { DownloadRow(item: $0) }
            }
            Text("Non ajoutés à l'historique des téléchargements. Les fichiers restent dans le dossier de téléchargement.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .tint(Theme.accent)
    }
}
