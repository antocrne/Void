import SwiftUI

/// Spaces, pinned tabs and tabs — the Mac's sidebar. A sheet on iPhone, a sidebar on iPad.
struct TabsPanel: View {
    /// In a sheet: picking a tab closes it.
    let inSheet: Bool
    let dismiss: () -> Void
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let space = browser.currentSpace
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, inSheet ? 22 : 10)
                .padding(.bottom, 8)

            List {
                if !space.pinned.isEmpty {
                    PinnedGrid(tabs: space.pinned, pick: pick)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(space.tabs) { tab in
                    TabRow(tab: tab, selected: space.selectedTabID == tab.id)
                        .contentShape(Rectangle())
                        .onTapGesture { pick(tab) }
                        .contextMenu { TabContextMenu(tab: tab) }
                        .swipeActions(edge: .trailing) {
                            Button { browser.requestClose(tab, force: true) } label: { Label("Fermer", systemImage: "xmark") }
                                .tint(Theme.danger)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    browser.moveTab(space.tabs[from], to: destination > from ? destination - 1 : destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 10)
            .overlay {
                if space.allTabs.isEmpty {
                    Text(browser.isPrivate ? "Aucun onglet privé" : "Aucun onglet dans cet espace")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            footer
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, inSheet ? 4 : 10)
        }
    }

    private func pick(_ tab: Tab) {
        browser.select(tab)
        dismiss()
    }

    // MARK: - Spaces

    @ViewBuilder
    private var header: some View {
        if browser.isPrivate {
            HStack(spacing: 10) {
                PrivateBadge()
                Text("Rien n'est conservé après la fermeture.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("Tout fermer") {
                    BrowserWindows.shared.closePrivate()
                    dismiss()
                }
                .font(.system(size: 14, weight: .medium))
            }
            .frame(minHeight: 38)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(browser.spaces) { space in
                        SpaceChip(space: space, selected: space.id == browser.currentSpaceID)
                    }
                    if browser.managesSpaces {
                        Button(action: addSpace) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 38, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Nouvel espace")
                    }
                }
            }
        }
    }

    private func addSpace() {
        Task {
            guard let name = await Dialogs.prompt(title: String(localized: "Nouvel espace"),
                                                  message: String(localized: "Chaque espace a ses onglets et ses propres cookies : un site peut y être connecté à un autre compte."),
                                                  fields: [Dialogs.Field(placeholder: String(localized: "Nom"))],
                                                  confirm: String(localized: "Créer"))?.first else { return }
            let icon = Space.iconChoices[browser.spaces.count % Space.iconChoices.count]
            browser.addSpace(name: name.trimmingCharacters(in: .whitespaces), icon: icon)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                dismiss()
                // Once the sheet is on its way out, so the address field can take the keyboard.
                DispatchQueue.main.asyncAfter(deadline: .now() + (inSheet ? 0.3 : 0)) { browser.showCommandBar(.newTab) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text(browser.isPrivate ? "Nouvel onglet privé" : "Nouvel onglet").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(Theme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.hover))
            }
            .buttonStyle(.plain)

            ChromeButton(symbol: browser.isPrivate ? "eye" : "eye.slash",
                         help: browser.isPrivate ? "Quitter la navigation privée" : "Navigation privée", active: browser.isPrivate) {
                if browser.isPrivate { BrowserWindows.shared.show(.shared) } else { BrowserWindows.shared.openPrivateWindow() }
            }
            .accessibilityLabel(browser.isPrivate ? "Quitter la navigation privée" : "Navigation privée")
            ChromeButton(symbol: "clock", help: "Historique, favoris, téléchargements") { browser.showLibrary(.history) }
                .accessibilityLabel("Bibliothèque")
            ChromeButton(symbol: "gearshape", help: "Réglages") { BrowserModel.shared.openSettingsAction?() }
                .accessibilityLabel("Réglages")
        }
    }
}

/// iPhone: the tabs panel, risen from the bottom over half the screen, or all of it when pulled up.
/// Not a system sheet: at mid-height one floats away from the edges (iOS 26) and the bottom bar
/// showed around it as a black band. This one stays against the sides and the bottom.
struct TabsDrawer: View {
    let close: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var expanded = false
    /// Downward drag of the top strip, in points.
    @State private var drag: CGFloat = 0

    /// The top strip (grabber and spaces) that moves the panel; below it, the list scrolls.
    private static let handleHeight: CGFloat = 76
    private static let space = "TabsDrawer"

    var body: some View {
        GeometryReader { geo in
            let medium = geo.size.height * 0.52
            let large = geo.size.height - 8
            let base = expanded ? large : medium
            // In the drawer's space, which stays put while the panel grows under the finger.
            let onHandle = { (value: DragGesture.Value) in value.startLocation.y - (geo.size.height - base) < Self.handleHeight }
            TabsPanel(inSheet: true, dismiss: close)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Theme.secondaryText.opacity(0.5))
                        .frame(width: 36, height: 5)
                        .padding(.top, 7)
                }
                .frame(height: min(large, max(0, base - drag)))
                .frame(maxWidth: .infinity)
                .background {
                    UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                        .fill(browser.isPrivate ? Theme.privateChrome : Theme.chrome)
                        .shadow(color: Theme.shadow.opacity(0.3), radius: 20, y: -4)
                        .ignoresSafeArea(edges: .bottom)
                }
                .privateChrome(browser.isPrivate)
                // Alongside the list's scrolling: only a drag that starts on the top strip counts.
                .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        guard onHandle(value) else { return }
                        drag = value.translation.height
                    }
                    .onEnded { value in
                        guard onHandle(value) else { return }
                        let end = base - value.predictedEndTranslation.height
                        withAnimation(Theme.spring) {
                            drag = 0
                            if end < medium * 0.6 {
                                close()
                            } else {
                                expanded = end > (medium + large) / 2
                            }
                        }
                    })
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .coordinateSpace(name: Self.space)
        .ignoresSafeArea(.keyboard)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
    }
}

/// A space in the row above the tabs: its icon, and its name when it is the current one.
private struct SpaceChip: View {
    let space: Space
    let selected: Bool
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        Button { browser.switchSpace(to: space) } label: {
            HStack(spacing: 6) {
                Image(systemName: space.icon).font(.system(size: 14, weight: .medium))
                if selected { Text(space.name).font(.system(size: 14.5, weight: .semibold)).lineLimit(1) }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
            .padding(.horizontal, selected ? 12 : 0)
            .frame(minWidth: 38)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Theme.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Espace \(space.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if browser.managesSpaces {
                Button { rename() } label: { Label("Renommer", systemImage: "pencil") }
                Menu {
                    ForEach(Space.iconChoices, id: \.self) { icon in
                        Button {
                            space.icon = icon
                            browser.setNeedsSave()
                        } label: { Label(icon == space.icon ? "Actuelle" : " ", systemImage: icon) }
                    }
                } label: { Label("Icône", systemImage: space.icon) }
                if browser.spaces.count > 1 {
                    Button(role: .destructive) { delete() } label: { Label("Supprimer l'espace…", systemImage: "trash") }
                }
            }
        }
    }

    private func rename() {
        Task {
            guard let name = await Dialogs.prompt(title: String(localized: "Renommer l'espace"), message: "",
                                                  fields: [Dialogs.Field(placeholder: String(localized: "Nom"), text: space.name)],
                                                  confirm: String(localized: "Renommer"))?.first,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            space.name = name.trimmingCharacters(in: .whitespaces)
            browser.setNeedsSave()
        }
    }

    private func delete() {
        Task {
            let tabs = space.allTabs.count
            guard await Dialogs.confirm(title: String(localized: "Supprimer l'espace « \(space.name) » ?"),
                                        message: tabs == 1 ? String(localized: "Son onglet et ses données de sites (cookies, sessions) sont supprimés.")
                                                           : String(localized: "Ses \(tabs) onglets et ses données de sites (cookies, sessions) sont supprimés."),
                                        confirm: String(localized: "Supprimer"), destructive: true) == true else { return }
            browser.deleteSpace(space)
        }
    }
}

/// Pinned tabs: icons only, kept after closing (closing one puts it to sleep).
private struct PinnedGrid: View {
    let tabs: [Tab]
    let pick: (Tab) -> Void
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 6)], spacing: 6) {
            ForEach(tabs) { tab in
                let selected = browser.selectedTab === tab
                FaviconView(tab: tab, size: 22)
                    .opacity(tab.isAsleep && !selected ? 0.55 : 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Theme.selection : Theme.hover))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                    .onTapGesture { pick(tab) }
                    .contextMenu { TabContextMenu(tab: tab) }
                    .accessibilityElement()
                    .accessibilityLabel("Onglet épinglé \(tab.displayTitle)")
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

private struct TabRow: View {
    let tab: Tab
    let selected: Bool
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        HStack(spacing: 11) {
            FaviconView(tab: tab, size: 20)
                .opacity(tab.isAsleep && !selected ? 0.55 : 1)
            Text(tab.displayTitle)
                .font(.system(size: 15.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.primaryText : Theme.primaryText.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 2)
            if tab.isInPiP || tab.isPlayingVideo {
                Image(systemName: tab.isInPiP ? "pip.fill" : (tab.isAudible ? "speaker.wave.2.fill" : "play.fill"))
                    .font(.system(size: 12))
                    .foregroundStyle(tab.isInPiP ? Theme.accent : Theme.secondaryText)
            }
            Button { browser.requestClose(tab, force: true) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Fermer l'onglet")
        }
        .padding(.leading, 12)
        .frame(height: 46)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.selection)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent).frame(width: 3, height: 18).padding(.leading, 4)
                    }
                    .shadow(color: Theme.shadow.opacity(0.08), radius: 1.5, y: 0.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Touch-and-hold menu shared by tab rows and pinned tiles.
private struct TabContextMenu: View {
    let tab: Tab
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        if browser.managesSpaces && !tab.isPrivate {
            Button { browser.togglePin(tab) } label: {
                Label(tab.isPinned ? "Désépingler" : "Épingler", systemImage: tab.isPinned ? "pin.slash" : "pin")
            }
        }
        if tab.isPinned && !tab.isAsleep {
            Button { browser.close(tab) } label: { Label("Mettre en veille", systemImage: "moon.zzz") }
        }
        if let url = tab.url {
            Button { browser.openTab(url: url, background: true, after: tab) } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
            Button { Clipboard.copy(url.absoluteString) } label: { Label("Copier le lien", systemImage: "link") }
        }
        if browser.spaces.count > 1 && !tab.isPrivate {
            Menu {
                ForEach(browser.spaces.filter { $0 !== tab.space }) { space in
                    Button { move(tab, to: space) } label: { Label(space.name, systemImage: space.icon) }
                }
            } label: { Label("Déplacer vers", systemImage: "arrow.right.square") }
        }
        Divider()
        Button(role: .destructive) { browser.requestClose(tab, force: true) } label: {
            Label(tab.isPinned ? "Fermer (désépingler)" : "Fermer l'onglet", systemImage: "xmark")
        }
        if !browser.otherTabs(than: tab).isEmpty {
            Button(role: .destructive) { browser.closeOtherTabs(than: tab) } label: {
                Label(tab.isPinned ? "Fermer les onglets non épinglés" : "Fermer les autres onglets", systemImage: "xmark.square")
            }
        }
    }

    private func move(_ tab: Tab, to space: Space) {
        // Storage is per space: the page is reloaded in the destination's data store.
        guard let url = tab.url else { return }
        let pinned = tab.isPinned
        browser.close(tab, force: true)
        let moved = browser.openTab(url: url, in: space, background: true)
        if pinned { browser.togglePin(moved) }
    }
}
