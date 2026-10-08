import SwiftUI

/// Top layout: one compact row — navigation, then the tabs; the active tab is the address field.
struct TopBarView: View {
    @Environment(BrowserModel.self) private var browser
    @Namespace private var selection
    @State private var reorder = TabReorder(layout: .horizontal, spacing: 4)
    @State private var pinnedReorder = TabReorder(layout: .horizontal, spacing: 4)
    @State private var creatingSpace = false

    var body: some View {
        let space = browser.currentSpace
        HStack(spacing: 4) {
            // Room for the traffic lights, which full screen hides.
            if !browser.isFullScreen { Color.clear.frame(width: 68) }

            if browser.isPrivate {
                PrivateBadge()
            } else if browser.spaces.count > 1 || browser.managesSpaces {
                // The spaces, as the sidebar's bottom bar has them: switch, or create one.
                Menu {
                    ForEach(browser.spaces) { s in
                        Button { browser.switchSpace(to: s) } label: { Label(s.name, systemImage: s.icon) }
                    }
                    if browser.managesSpaces {
                        Divider()
                        Button { creatingSpace = true } label: { Label("Nouvel espace…", systemImage: "plus") }
                    }
                } label: {
                    Label(space.name, systemImage: space.icon)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Theme.secondaryText)
                .fixedSize()
                .padding(.horizontal, 4)
                .help("Espace : \(space.name) (⌃⌘← / ⌃⌘→)")
                .popover(isPresented: $creatingSpace, arrowEdge: .bottom) { NewSpaceForm { creatingSpace = false } }
            }

            ChromeButton(symbol: "chevron.left", help: "Précédent (⌘[)", disabled: !(browser.selectedTab?.canGoBack ?? false)) { browser.goBack() }
            ChromeButton(symbol: "chevron.right", help: "Suivant (⌘])", disabled: !(browser.selectedTab?.canGoForward ?? false)) { browser.goForward() }
            ChromeButton(symbol: browser.selectedTab?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Recharger (⌘R)") {
                browser.selectedTab?.isLoading == true ? browser.stopLoading() : browser.reload()
            }

            // The row scrolls only when it doesn't fit; ＋ always stays right after it.
            ViewThatFits(in: .horizontal) {
                tabRow(space)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { tabRow(space) }
                        .onChange(of: space.selectedTabID, initial: true) { _, id in
                            guard let id else { return }
                            withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .center) }
                        }
                }
            }
            ChromeButton(symbol: "plus", help: "Nouvel onglet (⌘T)") { browser.showCommandBar(.newTab) }
            Spacer(minLength: 0)
            // The sidebar's tools, on the right.
            ExtensionsButton()
            if browser.isPrivate {
                ChromeButton(symbol: "xmark.circle", help: "Fermer la fenêtre privée et tout effacer (⌘⇧W)") { browser.window?.performClose(nil) }
            } else {
                ChromeButton(symbol: "eye.slash", help: "Nouvelle fenêtre privée (⌘⇧N)") { BrowserWindows.shared.openPrivateWindow() }
            }
            DownloadsButton()
        }
        .padding(.horizontal, 8)
        .background(SpaceSwipeCatcher { browser.switchSpace(by: $0) })
    }

    private func tabRow(_ space: Space) -> some View {
        HStack(spacing: 4) {
            ForEach(space.pinned) { tab in
                PinnedTile(tab: tab, selected: space.selectedTabID == tab.id, height: 30)
                    .frame(width: 36)
                    .tabReorderable(tab, with: pinnedReorder)
            }
            if !space.pinned.isEmpty {
                Divider().frame(height: 16).padding(.horizontal, 2)
            }
            ForEach(space.folders) { folder in
                TopFolderMenu(folder: folder, space: space)
            }
            if !space.folders.isEmpty {
                Divider().frame(height: 16).padding(.horizontal, 2)
            }
            // A pinned tab or a folder's tab has no pill to carry the address.
            if space.selectedTab.map({ selected in !space.tabs.contains { $0 === selected } }) ?? true {
                TopAddressField(tab: space.selectedTab)
            }
            ForEach(space.tabs) { tab in
                TopTabPill(tab: tab, selected: space.selectedTabID == tab.id, namespace: selection)
                    .tabReorderable(tab, with: reorder)
                    .id(tab.id)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 2)
        // Inside the scroll view when there is one: positions move with the scrolled row.
        .coordinateSpace(.named(reorder.coordinateSpace))
        .coordinateSpace(.named(pinnedReorder.coordinateSpace))
        .id(space.id)
        .transition(.push(from: browser.spaceTransitionEdge))
    }
}

/// A folder in the top bar: a menu of its tabs, to wake one up.
private struct TopFolderMenu: View {
    let folder: TabFolder
    let space: Space
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let holdsSelected = folder.tabs.contains { $0.id == space.selectedTabID }
        Menu {
            ForEach(folder.tabs) { tab in
                Toggle(tab.displayTitle, isOn: Binding(get: { tab.id == space.selectedTabID }, set: { _ in browser.select(tab) }))
            }
            if folder.tabs.isEmpty {
                Text("Vide · clic droit sur un onglet → Ranger dans un dossier")
            }
            Divider()
            Button("Renommer…") { browser.renamingFolderID = folder.id }
            Button("Supprimer le dossier, garder les onglets") { browser.deleteFolder(folder, keepingTabs: true) }
        } label: {
            Label(folder.name, systemImage: holdsSelected ? "folder.fill" : "folder")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(holdsSelected ? Theme.accent : Theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.secondaryText)
        .fixedSize()
        .padding(.horizontal, 4)
        .help(folder.tabs.count == 1 ? "\(folder.name) · 1 onglet" : "\(folder.name) · \(folder.tabs.count) onglets")
        .renameFolderPopover(folder, arrowEdge: .bottom)
    }
}
