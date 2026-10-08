import SwiftUI

/// Favicon, or the first letter of the site on a tinted tile (Settings → Onglets → Les onglets affichent).
struct FaviconView: View {
    let tab: Tab
    var size: CGFloat = 16
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if settings.tabIconStyle == .favicons, let image = tab.favicon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Theme.accentSoft)
                    .overlay(
                        Text(letter)
                            .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                    )
            }
        }
        .frame(width: size, height: size)
    }

    private var letter: String {
        let source = tab.url?.host()?.voidNormalizedHost ?? tab.displayTitle
        return source.first.map { String($0).uppercased() } ?? "•"
    }
}

/// Right-click menu shared by sidebar rows, pinned tiles and top pills.
struct TabContextMenu: View {
    let tab: Tab
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        if browser.managesSpaces && !tab.isPrivate {
            Button(tab.isPinned ? "Désépingler" : "Épingler") { browser.togglePin(tab) }
        }
        if tab.isPinned && !tab.isAsleep {
            Button("Mettre en veille") { browser.close(tab) }
        }
        Button("Recharger") { browser.select(tab); browser.reload() }
        if let url = tab.url {
            Button("Dupliquer") { browser.openTab(url: url, background: true, after: tab) }
            Button("Copier le lien") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        if tab.isInCall {
            Button(tab.isInFloatingPlayer ? "Ramener la réunion dans l'onglet" : "Réunion en fenêtre flottante") {
                Task { await PiPController.shared.toggle(tab) }
            }
        } else if tab.hasVideo {
            Button(tab.isInPiP ? "Quitter Picture in Picture" : "Picture in Picture") {
                Task { await PiPController.shared.toggle(tab) }
            }
        }
        if let selected = browser.selectedTab, selected !== tab, selected.space === tab.space,
           !browser.visibleTabs.contains(where: { $0 === tab }) {
            Button("Afficher côte à côte") { browser.showSideBySide(tab) }
        }
        if tab.space?.split?.contains(tab.id) == true {
            Button("Quitter la vue côte à côte") { browser.endSideBySide(of: tab) }
        }
        if browser.spaces.count > 1 && !tab.isPrivate {
            Menu("Déplacer vers") {
                ForEach(browser.spaces.filter { $0 !== tab.space }) { space in
                    Button(space.name) { move(tab, to: space) }
                }
            }
        }
        Divider()
        Button(tab.isPinned ? "Fermer (désépingler)" : "Fermer l'onglet") { browser.requestClose(tab, force: true) }
        if !browser.otherTabs(than: tab).isEmpty {
            Button(tab.isPinned ? "Fermer les onglets non épinglés" : "Fermer les autres onglets") { browser.closeOtherTabs(than: tab) }
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

/// A tab in the sidebar list.
struct SidebarTabRow: View {
    let tab: Tab
    let selected: Bool
    let namespace: Namespace.ID
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            FaviconView(tab: tab, size: 16)
                .opacity(tab.isAsleep && !selected ? 0.55 : 1)
            Text(tab.displayTitle)
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.primaryText : Theme.primaryText.opacity(0.78))
                .lineLimit(1)
            Spacer(minLength: 2)
            if tab.space?.split?.contains(tab.id) == true {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                    .help("Côte à côte")
            }
            if tab.isInCall {
                Button { Task { await PiPController.shared.toggle(tab) } } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(tab.isInFloatingPlayer ? Theme.accent : Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(tab.isInFloatingPlayer ? "Ramener la réunion dans l'onglet" : "Réunion en fenêtre flottante")
            } else if tab.isInPiP || tab.isPlayingVideo {
                Button { Task { await PiPController.shared.toggle(tab) } } label: {
                    Image(systemName: tab.isInPiP ? "pip.fill" : (tab.isAudible ? "speaker.wave.2.fill" : "play.fill"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(tab.isInPiP ? Theme.accent : Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(tab.isInPiP ? "Quitter Picture in Picture" : "Picture in Picture")
            }
            if hovering {
                Button { browser.requestClose(tab, force: true) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Theme.hover))
                }
                .buttonStyle(.plain)
                .help("Fermer l'onglet (⌘W)")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
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
        .contentShape(Rectangle())
        .onTapGesture { browser.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu { TabContextMenu(tab: tab) }
        .animation(Theme.quick, value: hovering)
    }
}

/// A pinned tab tile (favicon or letter). Persisted across launches.
struct PinnedTile: View {
    let tab: Tab
    let selected: Bool
    var height: CGFloat = 40
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        FaviconView(tab: tab, size: 17)
            .opacity(tab.isAsleep && !selected ? 0.5 : 1)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.selection : (hovering ? Theme.hover.opacity(1.6) : Theme.hover))
                    .shadow(color: Theme.shadow.opacity(selected ? 0.1 : 0), radius: 1.5, y: 0.5)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.75), lineWidth: 1.5)
                }
            }
            .overlay(alignment: .bottom) {
                if tab.isInPiP || tab.isPlayingVideo {
                    Capsule().fill(Theme.accent).frame(width: 10, height: 2.5).padding(.bottom, 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { browser.select(tab) }
            .onHover { hovering = $0 }
            .help(tab.displayTitle)
            .contextMenu { TabContextMenu(tab: tab) }
            .animation(Theme.quick, value: selected)
    }
}

/// A tab in the top bar layout. The active tab is also the address field (as in Safari's
/// compact layout): wider, it shows the site and its tools, and a click opens the command bar.
struct TopTabPill: View {
    let tab: Tab
    let selected: Bool
    let namespace: Namespace.ID
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false

    static let activeWidth: CGFloat = 360
    static let minWidth: CGFloat = 38

    var body: some View {
        HStack(spacing: 7) {
            FaviconView(tab: tab, size: 14)
            if selected {
                Text(tab.addressText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tab.url == nil ? Theme.secondaryText : Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected {
                AddressTools(tab: tab, showAll: hovering)
            }
            if !selected && (tab.isInPiP || tab.isPlayingVideo) {
                Image(systemName: tab.isInPiP ? "pip.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(tab.isInPiP ? Theme.accent : Theme.secondaryText)
            }
            if hovering || selected {
                Button { browser.requestClose(tab, force: true) } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.secondaryText)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fermer l'onglet (⌘W)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, selected ? 5 : 8)
        // The tab row proposes a shared width: the active tab must not accept less than its own.
        // Inactive tabs shrink with the room left (down to a favicon) instead of pushing the row into a scroll.
        .frame(minWidth: selected ? Self.activeWidth : Self.minWidth,
               idealWidth: selected ? Self.activeWidth : Self.minWidth,
               maxWidth: selected ? Self.activeWidth : 200)
        .clipped()
        .frame(height: 30)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.selection)
                    .overlay(alignment: .leading) {
                        ReadingProgressFill(progress: settings.showReadingProgress ? tab.readingProgress : 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: Theme.shadow.opacity(0.08), radius: 1.5, y: 0.5)
                    .matchedGeometryEffect(id: "top-selection", in: namespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selected ? browser.showCommandBar(.currentTab) : browser.select(tab) }
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .contextMenu { TabContextMenu(tab: tab) }
        .help(selected ? String(localized: "\(tab.displayTitle) — rechercher ou saisir une adresse (⌘L)") : tab.displayTitle)
    }
}

/// Top bar when the active tab can't carry the address (a pinned tile, or no tab at all):
/// the address field on its own, same size and place as an active tab.
struct TopAddressField: View {
    let tab: Tab?
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tab?.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 14)
            Text(tab?.addressText ?? Tab.addressPlaceholder)
                .font(.system(size: 12.5, weight: tab?.url == nil ? .regular : .medium))
                .foregroundStyle(tab?.url == nil ? Theme.secondaryText : Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let tab { AddressTools(tab: tab, showAll: hovering) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(width: TopTabPill.activeWidth, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
        .contentShape(Rectangle())
        .onTapGesture { browser.showCommandBar(tab == nil ? .newTab : .currentTab) }
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help("Rechercher ou saisir une adresse (⌘L)")
    }
}

/// The active tab fills up with the accent as the page is scrolled (Settings → Onglets).
private struct ReadingProgressFill: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Theme.accentSoft)
                .frame(width: geo.size.width * progress)
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
