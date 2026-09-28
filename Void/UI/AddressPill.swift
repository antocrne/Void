import SwiftUI

/// The single address field: shows the current site; a click opens the command bar
/// (URL, search, history, bookmarks, tabs, downloads). Tools appear only when relevant.
struct AddressPill: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false

    var body: some View {
        let tab = browser.selectedTab
        HStack(spacing: 4) {
            Image(systemName: leadingSymbol(tab))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 16)
            Text(tab?.addressText ?? Tab.addressPlaceholder)
                .font(.system(size: 12.5))
                .foregroundStyle(tab?.url == nil ? Theme.secondaryText : Theme.primaryText.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)

            if let tab { AddressTools(tab: tab, showAll: hovering) }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover))
        .contentShape(Rectangle())
        .onTapGesture { browser.showCommandBar(.currentTab) }
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help("Rechercher ou saisir une adresse (⌘L)")
    }

    private func leadingSymbol(_ tab: Tab?) -> String {
        guard let tab else { return "magnifyingglass" }
        if tab.isPrivate { return "eye.slash" }
        if tab.url?.scheme == "https" { return "lock.fill" }
        return tab.url == nil ? "magnifyingglass" : "globe"
    }

}

extension Tab {
    static let addressPlaceholder = "Rechercher ou saisir une adresse"

    /// What the address field shows: the site's host, or the whole URL when it has none.
    var addressText: String {
        guard let url else { return Self.addressPlaceholder }
        if let host = url.host() { return host.voidNormalizedHost }
        return url.absoluteString
    }
}

/// Tools of the address field, shown only when relevant: saved logins, PiP, and on hover
/// reader mode, ad blocker and bookmark. Shared by the sidebar's address pill and the
/// top bar's active tab.
struct AddressTools: View {
    let tab: Tab
    /// Hovered: every tool is offered, not only the active ones.
    let showAll: Bool
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 4) {
            if !tab.loginAccounts.isEmpty {
                Menu {
                    ForEach(tab.loginAccounts, id: \.self) { account in
                        Button(account.isEmpty ? "(sans identifiant)" : account) {
                            Task { await PasswordManager.shared.fill(tab, account: account) }
                        }
                    }
                } label: {
                    Image(systemName: "key.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Remplir le mot de passe (Touch ID)")
            }
            if tab.hasVideo || tab.isInPiP {
                ChromeButton(symbol: tab.isInPiP ? "pip.exit" : "pip.enter", help: "Picture in Picture (⌘⇧P)", active: tab.isInPiP, size: 12) {
                    browser.togglePiP()
                }
            }
            if showAll || tab.reader != nil {
                ChromeButton(symbol: "doc.plaintext", help: "Mode lecture (⌘⇧R)", active: tab.reader != nil, size: 12) { browser.toggleReader() }
            }
            if showAll, let host = tab.url?.host() {
                let active = settings.isAdBlockActive(on: host)
                ChromeButton(symbol: active ? "shield.lefthalf.filled" : "shield.slash", help: active ? "Bloqueur actif — cliquer pour le désactiver sur ce site" : "Bloqueur désactivé sur ce site", active: active, size: 12) {
                    browser.toggleAdBlockForCurrentSite()
                }
                ChromeButton(symbol: BookmarkStore.shared.isBookmarked(tab.url) ? "star.fill" : "star", help: "Favori (⌘D)", active: BookmarkStore.shared.isBookmarked(tab.url), size: 12) {
                    browser.toggleBookmark()
                }
            }
        }
    }
}
