import SwiftUI

/// iPhone: the only chrome on screen. Back, forward, the address, a new tab, the tabs and a menu.
/// A swipe up from it shows the tabs, as in Safari.
struct BottomBar: View {
    let showTabs: () -> Void
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let tab = browser.selectedTab
        HStack(spacing: 2) {
            ChromeButton(symbol: "chevron.left", help: "Précédent", disabled: !(tab?.canGoBack ?? false)) { browser.goBack() }
            ChromeButton(symbol: "chevron.right", help: "Suivant", disabled: !(tab?.canGoForward ?? false)) { browser.goForward() }
            AddressPill()
                .padding(.horizontal, 4)
            ChromeButton(symbol: "plus", help: browser.isPrivate ? "Nouvel onglet privé" : "Nouvel onglet") { browser.showCommandBar(.newTab) }
            TabsButton(action: showTabs)
            PageMenu()
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        // Alongside the address's sideways swipe and the buttons' taps, not instead of them.
        .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { value in
            let up = -min(value.translation.height, value.predictedEndTranslation.height)
            guard up > 50, abs(value.translation.height) > 1.5 * abs(value.translation.width) else { return }
            showTabs()
        })
    }
}

/// iPad: a thin bar above the page; the tabs are in the sidebar.
struct TopBar: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let tab = browser.selectedTab
        HStack(spacing: 4) {
            ChromeButton(symbol: "sidebar.left", help: "Barre latérale (⌃⌘S)") { browser.toggleSidebar() }
            ChromeButton(symbol: "chevron.left", help: "Précédent", disabled: !(tab?.canGoBack ?? false)) { browser.goBack() }
            ChromeButton(symbol: "chevron.right", help: "Suivant", disabled: !(tab?.canGoForward ?? false)) { browser.goForward() }
            if browser.isPrivate { PrivateBadge().padding(.leading, 4) }
            Spacer(minLength: 8)
            AddressPill()
                .frame(maxWidth: 560)
            Spacer(minLength: 8)
            ChromeButton(symbol: "plus", help: "Nouvel onglet (⌘T)") { browser.showCommandBar(.newTab) }
            PageMenu()
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
    }
}

/// The single address field: shows the current site; a tap opens the address bar. A swipe across
/// it goes to the next or previous tab; past the last one, to a new tab (as in Safari).
struct AddressPill: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let tab = browser.selectedTab
        HStack(spacing: 6) {
            Image(systemName: leadingSymbol(tab))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
            Text(tab?.url == nil ? "Recherche ou adresse" : tab?.addressText ?? "")
                .font(.system(size: 15.5))
                .foregroundStyle(tab?.url == nil ? Theme.secondaryText : Theme.primaryText.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if let tab { tools(tab) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 42)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.hover)
                .overlay(alignment: .leading) {
                    if settings.showReadingProgress, let tab { ReadingProgressFill(tab: tab) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .contentShape(Rectangle())
        .onTapGesture { browser.showCommandBar(.currentTab) }
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > 60, abs(value.translation.width) > 2 * abs(value.translation.height) else { return }
            let forward = value.translation.width < 0
            let tabs = browser.currentSpace.allTabs
            if forward, tab == nil || tab === tabs.last {
                browser.showCommandBar(.newTab)
            } else {
                browser.selectAdjacentTab(forward ? 1 : -1)
            }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Adresse")
        .accessibilityValue(tab?.addressText ?? "")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func tools(_ tab: Tab) -> some View {
        if !tab.loginAccounts.isEmpty {
            Menu {
                ForEach(tab.loginAccounts, id: \.self) { account in
                    Button(account.isEmpty ? "(sans identifiant)" : account) {
                        Task { await PasswordManager.shared.fill(tab, account: account) }
                    }
                }
            } label: {
                Image(systemName: "key.fill").font(.system(size: 14)).foregroundStyle(Theme.accent).frame(width: 34, height: 38)
            }
            .accessibilityLabel("Remplir le mot de passe")
        }
        if tab.isLoading {
            ChromeButton(symbol: "xmark", help: "Arrêter", size: 10.5) { browser.stopLoading() }
        } else if tab.url != nil {
            ChromeButton(symbol: "arrow.clockwise", help: "Recharger", size: 10.5) { browser.reload() }
        }
    }

    private func leadingSymbol(_ tab: Tab?) -> String {
        if browser.isPrivate { return "eye.slash" }
        guard let tab else { return "magnifyingglass" }
        if tab.url?.scheme == "https" { return tab.hasOnlySecureContent ? "lock.fill" : "lock.trianglebadge.exclamationmark" }
        return tab.url == nil ? "magnifyingglass" : "globe"
    }
}

/// The address field fills up with the accent as the page is scrolled (Réglages). Its own view:
/// it changes at every frame of a scroll, the rest of the bar doesn't.
private struct ReadingProgressFill: View {
    let tab: Tab

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Theme.accentSoft)
                .frame(width: geo.size.width * tab.readingProgress)
                .opacity(tab.readingProgress > 0.005 ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Opens the tabs; shows how many the space has. Touch and hold: new tab, close this one.
private struct TabsButton: View {
    let action: () -> Void
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let count = browser.currentSpace.allTabs.count
        Button(action: action) {
            Text(count > 99 ? "∞" : "\(count)")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 23, height: 21)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.secondaryText, lineWidth: 1.6))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { browser.showCommandBar(.newTab) } label: { Label("Nouvel onglet", systemImage: "plus") }
            if !browser.isPrivate {
                Button { BrowserWindows.shared.openPrivateWindow() } label: { Label("Navigation privée", systemImage: "eye.slash") }
            }
            if let tab = browser.selectedTab {
                Button(role: .destructive) { browser.closeCurrentTab() } label: { Label("Fermer cet onglet", systemImage: "xmark") }
                if !browser.otherTabs(than: tab).isEmpty {
                    Button(role: .destructive) { browser.closeOtherTabs(than: tab) } label: { Label("Fermer les autres onglets", systemImage: "xmark.square") }
                }
            }
        }
        .accessibilityLabel("Onglets")
        .accessibilityValue("\(count)")
    }
}

/// Everything else, out of the way: what the Mac puts in its menu bar and address field.
struct PageMenu: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let tab = browser.selectedTab
        Menu {
            Section {
                Button { browser.showCommandBar(.newTab) } label: { Label("Nouvel onglet", systemImage: "plus") }
                if browser.isPrivate {
                    Button { BrowserWindows.shared.show(.shared) } label: { Label("Quitter la navigation privée", systemImage: "eye") }
                } else {
                    Button { BrowserWindows.shared.openPrivateWindow() } label: { Label("Navigation privée", systemImage: "eye.slash") }
                }
            }
            if let tab, let url = tab.url {
                Section {
                    ShareLink(item: url) { Label("Partager…", systemImage: "square.and.arrow.up") }
                    Button { browser.copyURL() } label: { Label("Copier le lien", systemImage: "link") }
                    let bookmarked = BookmarkStore.shared.isBookmarked(url)
                    Button { browser.toggleBookmark() } label: {
                        Label(bookmarked ? "Retirer des favoris" : "Ajouter aux favoris", systemImage: bookmarked ? "star.fill" : "star")
                    }
                    if browser.managesSpaces {
                        Button { browser.togglePin(tab) } label: {
                            Label(tab.isPinned ? "Désépingler l'onglet" : "Épingler l'onglet", systemImage: tab.isPinned ? "pin.slash" : "pin")
                        }
                    }
                }
                Section {
                    Button { browser.toggleReader() } label: {
                        Label(tab.reader == nil ? "Mode lecture" : "Quitter le mode lecture", systemImage: "doc.plaintext")
                    }
                    Button { browser.toggleFind() } label: { Label("Rechercher dans la page", systemImage: "magnifyingglass") }
                    if tab.hasVideo || tab.isInPiP {
                        Button { browser.togglePiP() } label: {
                            Label(tab.isInPiP ? "Quitter Picture in Picture" : "Picture in Picture", systemImage: tab.isInPiP ? "pip.exit" : "pip.enter")
                        }
                    }
                    if let host = url.host() {
                        let active = settings.isAdBlockActive(on: host)
                        Button { browser.toggleAdBlockForCurrentSite() } label: {
                            Label(active ? "Désactiver le bloqueur sur ce site" : "Réactiver le bloqueur sur ce site",
                                  systemImage: active ? "shield.lefthalf.filled" : "shield.slash")
                        }
                    }
                    Button { browser.hideElement() } label: { Label("Masquer un élément…", systemImage: "eye.slash") }
                    if VoidNotes.shared.isInstalled {
                        Button { browser.sendPageToNotes() } label: { Label("Envoyer vers Void Notes", systemImage: "note.text") }
                    }
                    Button { browser.print() } label: { Label("Imprimer…", systemImage: "printer") }
                }
            }
            Section {
                Button { browser.showLibrary(.bookmarks) } label: { Label("Favoris", systemImage: "star") }
                Button { browser.showLibrary(.history) } label: { Label("Historique", systemImage: "clock") }
                Button { browser.showLibrary(.downloads) } label: { Label("Téléchargements", systemImage: "arrow.down.circle") }
                Button { BrowserModel.shared.openSettingsAction?() } label: { Label("Réglages", systemImage: "gearshape") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Menu")
    }
}
