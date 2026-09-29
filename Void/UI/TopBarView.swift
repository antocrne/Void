import SwiftUI

/// Top layout: one compact row — navigation, then the tabs; the active tab is the address field.
struct TopBarView: View {
    @Environment(BrowserModel.self) private var browser
    @Namespace private var selection
    @State private var reorder = TabReorder(layout: .horizontal, spacing: 4)
    @State private var pinnedReorder = TabReorder(layout: .horizontal, spacing: 4)

    var body: some View {
        let space = browser.currentSpace
        HStack(spacing: 4) {
            Color.clear.frame(width: 68)

            if browser.isPrivate {
                PrivateBadge()
            } else if browser.spaces.count > 1 {
                // Only worth showing when there is a choice to make.
                Menu {
                    ForEach(browser.spaces) { s in
                        Button { browser.switchSpace(to: s) } label: { Label(s.name, systemImage: s.icon) }
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
            ExtensionsButton()
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
            if space.selectedTab?.isPinned != false {
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
