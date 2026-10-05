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
                // Highlighted while the new-tab page is shown, as the tab it stands for.
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(space.selectedTabID == nil ? Theme.selection : (hoveringNew ? Theme.hover : .clear)))
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
    @State private var confirmingDeletion = false

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
        .spaceDeletionDialog(space: confirmingDeletion ? space : nil, dismiss: { confirmingDeletion = false }) {
            browser.deleteSpace($0)
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
        Button("Supprimer l'espace…", role: .destructive) { confirmingDeletion = true }
            .disabled(browser.spaces.count < 2)
    }
}

extension View {
    /// "Supprimer l'espace … ?": its tabs close and its website data goes, so it is always asked
    /// (the sidebar's menu and Settings alike). Shown while `space` isn't nil.
    func spaceDeletionDialog(space: Space?, dismiss: @escaping () -> Void, delete: @escaping (Space) -> Void) -> some View {
        confirmationDialog("Supprimer l'espace « \(space?.name ?? "") » ?",
                           isPresented: Binding(get: { space != nil }, set: { if !$0 { dismiss() } }),
                           presenting: space) { space in
            Button("Supprimer l'espace et ses données", role: .destructive) { delete(space) }
        } message: { _ in
            Text("Ses onglets sont fermés et ses données de sites (cookies, sessions, cache) sont effacées.")
        }
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

/// The downloads popover, like Safari's: the history — or, in a private window, that window's
/// downloads, never added to the history.
struct DownloadsButton: View {
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        @Bindable var browser = browser
        let progress = DownloadManager.shared.progress(for: browser)
        let speed = DownloadManager.shared.speedText(for: browser)
        Button {
            browser.showingDownloads.toggle()
        } label: {
            Group {
                if let progress {
                    DownloadProgressIcon(progress: progress)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering || browser.showingDownloads ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Téléchargements (⌥⌘L)" + (speed.map { " · \($0)" } ?? ""))
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .onAppear { browser.downloadsButtonsShown += 1 }
        .onDisappear {
            browser.downloadsButtonsShown -= 1
            if browser.downloadsButtonsShown == 0 { browser.showingDownloads = false }
        }
        .popover(isPresented: $browser.showingDownloads, arrowEdge: .top) {
            DownloadsPopover(browser: browser)
        }
    }
}

/// The arrow inside a thin ring that fills up as the downloads progress; a short arc turns while
/// no size is known. Grey while everything is paused.
private struct DownloadProgressIcon: View {
    let progress: DownloadManager.Progress
    @State private var spinning = false

    private static let diameter: CGFloat = 15

    var body: some View {
        let tint = progress.paused ? Theme.secondaryText : Theme.accent
        ZStack {
            Circle().stroke(Theme.secondaryText.opacity(0.28), lineWidth: 1.5)
            if let fraction = progress.fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // WebKit's progress comes twice a second: the ring glides between reports.
                    .animation(.linear(duration: 0.5), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .animation(progress.paused ? .default : .linear(duration: 1.1).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = !progress.paused }
                    .onChange(of: progress.paused) { spinning = !progress.paused }
            }
            Image(systemName: progress.paused ? "pause.fill" : "arrow.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityElement()
        .accessibilityLabel("Téléchargements")
        .accessibilityValue(progress.fraction.map { "\(Int($0 * 100)) %" } ?? (progress.paused ? "En pause" : "En cours"))
    }
}

private struct DownloadsPopover: View {
    let browser: BrowserModel

    var body: some View {
        let manager = DownloadManager.shared
        let items = browser.isPrivate ? manager.items(of: browser) : manager.history
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(browser.isPrivate ? "Téléchargements de cette fenêtre" : "Téléchargements").font(.headline)
                Spacer()
                if !browser.isPrivate {
                    Button("Effacer") { manager.clearFinished() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .disabled(!items.contains { $0.state != .running && $0.state != .paused })
                }
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 8)
            if items.isEmpty {
                Text("Aucun téléchargement.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(items) { DownloadRow(item: $0) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, 8)
            if browser.isPrivate {
                Text("Non ajoutés à l'historique des téléchargements. Les fichiers restent dans le dossier de téléchargement.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            } else {
                Button("Tout afficher…") {
                    browser.showingDownloads = false
                    browser.showLibrary(.downloads)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 340)
        .tint(Theme.accent)
    }
}
