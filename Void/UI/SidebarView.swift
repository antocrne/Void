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
                if browser.managesSpaces {
                    Button { browser.addFolder(in: space) } label: {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11.5, weight: .medium))
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Nouveau dossier, pour ranger des onglets à voir plus tard (⌃⌘N)")
                }
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
                    ForEach(space.folders) { folder in
                        TabFolderRow(folder: folder, reorder: reorder)
                        if folder.isExpanded && folder.tabs.isEmpty {
                            Text("Vide · glissez-y un onglet")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondaryText.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 34)
                                .frame(height: 24)
                        }
                        ForEach(folder.shownTabs(selectedID: space.selectedTabID)) { tab in
                            SidebarTabRow(tab: tab, selected: space.selectedTabID == tab.id, namespace: namespace, indent: 16)
                                .tabReorderable(tab, with: reorder)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    if !space.folders.isEmpty {
                        // Where the space's own tabs begin: a folder's tab released below comes out of it.
                        Divider()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(reorder.coordinateSpace)).midY } action: {
                                reorder.recordLooseTop($0)
                            }
                    }
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

/// A folder's header: a click folds or unfolds it; a tab dragged onto it goes in.
private struct TabFolderRow: View {
    let folder: TabFolder
    let reorder: TabReorder
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false
    @State private var confirmingDeletion = false

    var body: some View {
        let target = reorder.dropTarget == folder.id
        HStack(spacing: 9) {
            Image(systemName: target ? "folder.fill" : "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(target ? Theme.accent : Theme.secondaryText)
                .frame(width: 16)
            Text(folder.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.primaryText.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 2)
            if !folder.isExpanded || hovering {
                Text("\(folder.tabs.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(target ? Theme.accentSoft : (hovering ? Theme.hover : .clear))
        }
        .overlay {
            if target {
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.accent.opacity(0.75), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { browser.toggleFolder(folder) }
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(reorder.coordinateSpace)) } action: {
            reorder.recordFolder($0, for: folder.id)
        }
        .help(folder.isExpanded ? "Replier le dossier" : "Déplier le dossier")
        .contextMenu {
            Button("Renommer…") { browser.renamingFolderID = folder.id }
            Button(folder.isExpanded ? "Replier" : "Déplier") { browser.toggleFolder(folder) }
            if folder.tabs.contains(where: { !$0.isAsleep }) {
                Button("Mettre les onglets en veille") { for tab in folder.tabs { browser.sleepTab(tab) } }
            }
            Divider()
            Button("Supprimer le dossier, garder les onglets") { browser.deleteFolder(folder, keepingTabs: true) }
            Button("Supprimer le dossier et ses onglets…", role: .destructive) {
                if folder.tabs.isEmpty { browser.deleteFolder(folder, keepingTabs: false) } else { confirmingDeletion = true }
            }
        }
        .renameFolderPopover(folder)
        .confirmationDialog("Supprimer le dossier « \(folder.name) » et ses onglets ?", isPresented: $confirmingDeletion) {
            Button(folder.tabs.count == 1 ? "Fermer 1 onglet et supprimer" : "Fermer \(folder.tabs.count) onglets et supprimer", role: .destructive) {
                browser.deleteFolder(folder, keepingTabs: false)
            }
        } message: {
            Text("⌘⇧T rouvre les onglets fermés un par un.")
        }
    }
}

/// Bottom of the sidebar: private window, downloads, extensions and the pinned ones (as many as
/// fit), spaces (none in a private window).
private struct SpaceBar: View {
    @Environment(BrowserModel.self) private var browser
    @State private var creating = false
    @State private var width: CGFloat?

    /// A button and the gap after it; the least room between the tools and the spaces.
    private static let slot: CGFloat = 28, minGap: CGFloat = 8

    /// The pinned extensions' room: the bar's width less every other button.
    private var pinRoom: Int? {
        guard let width else { return nil }
        let others = browser.isPrivate
            ? 3   // downloads, 🧩, close
            : 3 + browser.spaces.count + (browser.managesSpaces ? 1 : 0)   // private window, downloads, 🧩, spaces, +
        return max(0, Int((width - Self.minGap) / Self.slot) - others)
    }

    var body: some View {
        HStack(spacing: 2) {
            if !browser.isPrivate {
                ChromeButton(symbol: "eye.slash", help: "Nouvelle fenêtre privée (⌘⇧N)") { BrowserWindows.shared.openPrivateWindow() }
            }
            DownloadsButton()
            ExtensionsButton(sidebarRoom: pinRoom)
            Spacer(minLength: Self.minGap)
            if browser.isPrivate {
                ChromeButton(symbol: "xmark.circle", help: "Fermer la fenêtre privée et tout effacer (⌘⇧W)") { browser.window?.performClose(nil) }
            } else {
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

struct SpaceIconButton: View {
    let space: Space
    let selected: Bool
    @Environment(BrowserModel.self) private var browser
    @State private var renaming = false
    @State private var confirmingDeletion = false

    var body: some View {
        ChromeButton(symbol: space.icon, verbatimHelp: space.name, active: selected) {
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
        .help(speed.map { speed -> LocalizedStringKey in "Téléchargements (⌥⌘L) · \(speed)" } ?? "Téléchargements (⌥⌘L)")
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
        .accessibilityValue(progress.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
                            ?? (progress.paused ? String(localized: "En pause") : String(localized: "En cours")))
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
