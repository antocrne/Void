import SwiftUI

/// The sidebar reduced to a column of icons (Settings → Onglets, Présentation, or its edge pulled
/// all the way to the left): pinned tabs, new tab, folders and tabs as favicons or initials — the
/// title shows on hover — then the spaces and the tools. Navigation and the address move to the
/// bar above the page.
struct SidebarRail: View {
    static let width: CGFloat = 52
    @Environment(BrowserModel.self) private var browser
    @Namespace private var selection

    var body: some View {
        let space = browser.currentSpace
        VStack(spacing: 6) {
            ZStack {
                RailTabList(space: space, namespace: selection)
                    .id(space.id)
                    .transition(.push(from: browser.spaceTransitionEdge))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()

            RailTools()
        }
        .padding(.bottom, 8)
        .background(SpaceSwipeCatcher { browser.switchSpace(by: $0) })
    }
}

private struct RailTabList: View {
    let space: Space
    let namespace: Namespace.ID
    @Environment(BrowserModel.self) private var browser
    @State private var pinnedReorder = TabReorder(layout: .vertical, spacing: 4)
    @State private var reorder = TabReorder(layout: .vertical, spacing: 4)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                if !space.pinned.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(space.pinned) { tab in
                            PinnedTile(tab: tab, selected: space.selectedTabID == tab.id, height: 36)
                                .tabReorderable(tab, with: pinnedReorder)
                        }
                    }
                    .coordinateSpace(.named(pinnedReorder.coordinateSpace))
                    Divider().padding(.horizontal, 6)
                }

                RailNewTabButton(selected: space.selectedTabID == nil)

                LazyVStack(spacing: 4) {
                    ForEach(space.folders) { folder in
                        RailFolderButton(folder: folder, reorder: reorder)
                        ForEach(folder.shownTabs(selectedID: space.selectedTabID)) { tab in
                            RailTabButton(tab: tab, selected: space.selectedTabID == tab.id, namespace: namespace, inFolder: true)
                                .tabReorderable(tab, with: reorder)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    if !space.folders.isEmpty {
                        // Where the space's own tabs begin: a folder's tab released below comes out of it.
                        Divider()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(reorder.coordinateSpace)).midY } action: {
                                reorder.recordLooseTop($0)
                            }
                    }
                    ForEach(space.tabs) { tab in
                        RailTabButton(tab: tab, selected: space.selectedTabID == tab.id, namespace: namespace)
                            .tabReorderable(tab, with: reorder)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .coordinateSpace(.named(reorder.coordinateSpace))
            }
            // Inside the scroll view: a tab's close button sticks out of its tile.
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }
}

/// A tab of the reduced sidebar: its favicon or initial; the title as a tooltip.
private struct RailTabButton: View {
    let tab: Tab
    let selected: Bool
    let namespace: Namespace.ID
    /// A folder's tabs have a thin line on their left, like a step to the right.
    var inFolder = false
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false

    var body: some View {
        FaviconView(tab: tab, size: 16)
            .opacity(tab.isAsleep && !selected ? 0.55 : 1)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.selection)
                        .overlay(alignment: .leading) {
                            ReadingProgressFill(progress: settings.showReadingProgress ? tab.readingProgress : 0)
                        }
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.accent).frame(width: 3, height: 14).padding(.leading, 3)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .shadow(color: Theme.shadow.opacity(0.08), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover)
                }
            }
            .overlay(alignment: .leading) {
                if inFolder {
                    Capsule().fill(Theme.secondaryText.opacity(0.35)).frame(width: 2, height: 18).offset(x: -5)
                }
            }
            .overlay(alignment: .bottomTrailing) { mediaBadge }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { browser.requestClose(tab, force: true) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(Theme.chrome))
                            .background(Circle().fill(Theme.hover).padding(-1))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                    .help("Fermer l'onglet (⌘W)")
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { browser.select(tab) }
            .onHover { hovering = $0 }
            .help(tab.displayTitle)
            .contextMenu { TabContextMenu(tab: tab) }
            .animation(Theme.quick, value: hovering)
    }

    /// A call, Picture in Picture or a video playing: a small sign in the corner of the tile.
    @ViewBuilder private var mediaBadge: some View {
        let symbol: String? = if tab.isInCall { "video.fill" }
            else if tab.isInPiP { "pip.fill" }
            else if tab.isPlayingVideo { tab.isAudible ? "speaker.wave.2.fill" : "play.fill" }
            else { nil }
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(tab.isInPiP || tab.isInFloatingPlayer ? Theme.accent : Theme.secondaryText)
                .padding(4)
        }
    }
}

private struct RailNewTabButton: View {
    /// The new-tab page is shown: highlighted, as the tab it stands for.
    let selected: Bool
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        Button { browser.showCommandBar(.newTab) } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.selection : (hovering ? Theme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Nouvel onglet (⌘T)")
    }
}

/// A folder of the reduced sidebar: a click folds or unfolds it; a tab dragged onto it goes in.
private struct RailFolderButton: View {
    let folder: TabFolder
    let reorder: TabReorder
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        let target = reorder.dropTarget == folder.id
        Image(systemName: target || folder.isExpanded ? "folder.fill" : "folder")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(target ? Theme.accent : Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .overlay(alignment: .bottomTrailing) {
                if !folder.isExpanded && !folder.tabs.isEmpty {
                    Text("\(folder.tabs.count)")
                        .font(.system(size: 8.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.trailing, 4)
                        .padding(.bottom, 2)
                }
            }
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
            .help(folder.isExpanded ? Text("\(folder.name) — replier") : Text("\(folder.name) — déplier"))
            .folderActions(folder)
    }
}

/// Bottom of the reduced sidebar, one above the other: spaces (or, in a private window, its close
/// button), then downloads, extensions and the private window.
private struct RailTools: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var creating = false

    var body: some View {
        if settings.minimalist { minimal } else { full }
    }

    /// Minimalist: the spaces (when there are several), then the menu button.
    private var minimal: some View {
        VStack(spacing: 2) {
            if !browser.isPrivate && browser.spaces.count > 1 {
                ForEach(browser.spaces) { space in
                    SpaceIconButton(space: space, selected: space.id == browser.currentSpaceID)
                }
                Divider().frame(width: 24).padding(.vertical, 4)
            }
            MinimalMenuButton(arrowEdge: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var full: some View {
        VStack(spacing: 2) {
            if browser.isPrivate {
                ChromeButton(symbol: "xmark.circle", help: "Fermer la fenêtre privée et tout effacer (⌘⇧W)") { browser.window?.performClose(nil) }
            } else {
                ForEach(browser.spaces) { space in
                    SpaceIconButton(space: space, selected: space.id == browser.currentSpaceID)
                }
                if browser.managesSpaces {
                    ChromeButton(symbol: "plus", help: "Nouvel espace") { creating = true }
                        .popover(isPresented: $creating, arrowEdge: .trailing) { NewSpaceForm { creating = false } }
                }
            }
            Divider().frame(width: 24).padding(.vertical, 4)
            DownloadsButton()
            ExtensionsButton(vertical: true)
            if !browser.isPrivate {
                ChromeButton(symbol: "eye.slash", help: "Nouvelle fenêtre privée (⌘⇧N)") { BrowserWindows.shared.openPrivateWindow() }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
