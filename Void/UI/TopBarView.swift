import SwiftUI

/// Top layout: one compact row — navigation, address, tabs.
struct TopBarView: View {
    @Environment(BrowserModel.self) private var browser
    @Namespace private var selection

    var body: some View {
        let space = browser.currentSpace
        HStack(spacing: 4) {
            Color.clear.frame(width: 68)

            if browser.isPrivate {
                PrivateBadge()
            } else {
                Menu {
                    ForEach(browser.spaces) { s in
                        Button { browser.switchSpace(to: s) } label: { Label(s.name, systemImage: s.icon) }
                    }
                } label: {
                    Image(systemName: space.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Espace : \(space.name)")
            }

            ChromeButton(symbol: "chevron.left", help: "Précédent (⌘[)", disabled: !(browser.selectedTab?.canGoBack ?? false)) { browser.goBack() }
            ChromeButton(symbol: "chevron.right", help: "Suivant (⌘])", disabled: !(browser.selectedTab?.canGoForward ?? false)) { browser.goForward() }
            ChromeButton(symbol: browser.selectedTab?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Recharger (⌘R)") {
                browser.selectedTab?.isLoading == true ? browser.stopLoading() : browser.reload()
            }

            AddressPill()
                .frame(minWidth: 220, idealWidth: 340, maxWidth: 380)

            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(space.pinned) { tab in
                        PinnedTile(tab: tab, selected: space.selectedTabID == tab.id, height: 30)
                            .frame(width: 36)
                    }
                    if !space.pinned.isEmpty {
                        Divider().frame(height: 16).padding(.horizontal, 2)
                    }
                    ForEach(space.tabs) { tab in
                        TopTabPill(tab: tab, selected: space.selectedTabID == tab.id, namespace: selection)
                            .id(tab.id)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 2)
                .id(space.id)
                .transition(.push(from: browser.spaceTransitionEdge))
            }
            .onChange(of: space.selectedTabID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .center) }
            }
            }

            ChromeButton(symbol: "plus", help: "Nouvel onglet (⌘T)") { browser.showCommandBar(.newTab) }
            DownloadsButton()
        }
        .padding(.horizontal, 8)
        .background(SpaceSwipeCatcher { browser.switchSpace(by: $0) })
    }
}
