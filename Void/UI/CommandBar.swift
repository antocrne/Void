import SwiftUI

struct Suggestion: Identifiable {
    enum Kind {
        case go(URL)
        case search(String)
        case switchTo(Tab)
        case download(DownloadItem)
        /// A result to copy (a conversion).
        case copy(String)
        case action(() -> Void)
    }
    let symbol: String
    let title: String
    let subtitle: String
    let kind: Kind

    /// Stable across recomputations (same target = same row), so SwiftUI keeps rows in place.
    var id: String {
        switch kind {
        case .go(let url): "go:" + url.absoluteString
        case .search(let text): "search:" + text
        case .switchTo(let tab): "tab:" + tab.id.uuidString
        case .download(let item): "download:" + item.id.uuidString
        case .copy(let text): "copy:" + text
        case .action: "action:" + title
        }
    }
}

/// Builds address-bar suggestions: URL/search, open tabs, bookmarks, history, downloads.
/// Private windows get no history-based suggestions and only their own downloads.
@MainActor
enum SuggestionEngine {
    static func suggestions(for raw: String, browser: BrowserModel) -> [Suggestion] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        var out: [Suggestion] = []
        var seen = Set<String>()
        let lower = text.lowercased()
        let useHistory = !browser.isPrivate

        guard !text.isEmpty else {
            guard useHistory else { return [] }
            return HistoryStore.shared.topSites(limit: 6).map {
                Suggestion(symbol: "clock", title: $0.title.isEmpty ? $0.url.host() ?? "" : $0.title,
                           subtitle: $0.url.absoluteString, kind: .go($0.url))
            }
        }

        if let url = URLResolver.url(from: text) {
            out.append(Suggestion(symbol: "globe", title: url.absoluteString, subtitle: "Ouvrir", kind: .go(url)))
            seen.insert(url.absoluteString)
        }
        let engine = AppSettings.shared.searchEngine.name
        out.append(Suggestion(symbol: "magnifyingglass", title: text, subtitle: "Rechercher avec \(engine)", kind: .search(text)))
        // « 10 km en miles », « 100 usd en eur »: the answer, right under the search (↩ still searches).
        switch QuickConverter.answer(for: text) {
        case .result(let result):
            out.append(Suggestion(symbol: "equal.circle", title: result.text,
                                  subtitle: [result.note, "Copier"].compactMap { $0 }.joined(separator: " · "), kind: .copy(result.value)))
        case .loading:
            out.append(Suggestion(symbol: "equal.circle", title: "Conversion…", subtitle: "Taux de change en cours de chargement", kind: .action({})))
        case nil:
            break
        }

        for tab in browser.allTabs where tab !== browser.selectedTab {
            guard out.count < 5 else { break }
            let hay = (tab.title + " " + (tab.url?.absoluteString ?? "")).lowercased()
            if hay.contains(lower) {
                out.append(Suggestion(symbol: "square.on.square", title: tab.displayTitle,
                                      subtitle: "Aller à l'onglet · \(tab.space?.name ?? "")", kind: .switchTo(tab)))
            }
        }
        for bookmark in BookmarkStore.shared.search(text, limit: 4) where !seen.contains(bookmark.url.absoluteString) {
            seen.insert(bookmark.url.absoluteString)
            out.append(Suggestion(symbol: "star", title: bookmark.title, subtitle: bookmark.url.absoluteString, kind: .go(bookmark.url)))
        }
        for entry in useHistory ? HistoryStore.shared.search(text, limit: 6) : [] where !seen.contains(entry.url.absoluteString) {
            seen.insert(entry.url.absoluteString)
            out.append(Suggestion(symbol: "clock", title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                  subtitle: entry.url.absoluteString, kind: .go(entry.url)))
        }
        let downloads = browser.isPrivate ? DownloadManager.shared.items(of: browser) : DownloadManager.shared.history
        for item in downloads where item.filename.lowercased().contains(lower) {
            out.append(Suggestion(symbol: "arrow.down.doc", title: item.filename, subtitle: "Téléchargement", kind: .download(item)))
        }

        let actions: [(keys: [String], symbol: String, title: String, run: () -> Void)] = [
            (["télécharg", "telecharg", "download"], "arrow.down.circle", "Afficher les téléchargements", { browser.showLibrary(.downloads) }),
            (["histo", "history"], "clock", "Afficher l'historique", { browser.showLibrary(.history) }),
            (["favori", "bookmark", "signet"], "star", "Afficher les favoris", { browser.showLibrary(.bookmarks) }),
            (["réglage", "reglage", "setting", "préf", "pref"], "gearshape", "Ouvrir les réglages", { browser.openSettingsAction?() }),
        ]
        for action in actions where action.keys.contains(where: { lower.hasPrefix($0) || $0.hasPrefix(lower) && lower.count >= 4 }) {
            out.append(Suggestion(symbol: action.symbol, title: action.title, subtitle: "Void", kind: .action(action.run)))
        }
        var ids = Set<String>()
        return Array(out.filter { ids.insert($0.id).inserted }.prefix(12))
    }
}

/// Floating command bar (⌘L / ⌘T): one field for URLs and searches.
struct CommandBarOverlay: View {
    let request: CommandBarRequest
    /// Width of the docked sidebar: the bar is centered on the page, not on the whole window.
    var leadingInset: CGFloat = 0
    @Environment(BrowserModel.self) private var browser
    @State private var text = ""
    @State private var selection = 0
    /// Recomputed when the text changes only (not on every hover, which re-renders the body):
    /// it queries the history database.
    @State private var suggestions: [Suggestion] = []
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            content(width: min(640, max(320, geo.size.width - leadingInset - 32)))
        }
        .onAppear {
            text = request.text
            suggestions = SuggestionEngine.suggestions(for: text, browser: browser)
            DispatchQueue.main.async { focused = true }
        }
    }

    private func content(width: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: browser.isPrivate ? "eye.slash" : (request.mode == .newTab ? "plus.magnifyingglass" : "magnifyingglass"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(focused ? Theme.accent : Theme.secondaryText)
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .focusEffectDisabled()
                        .onSubmit { commit(suggestions) }
                        .onKeyPress(.upArrow) { move(-1, count: suggestions.count); return .handled }
                        .onKeyPress(.downArrow) { move(1, count: suggestions.count); return .handled }
                        .onKeyPress(.escape) { dismiss(); return .handled }
                        .onChange(of: text) {
                            selection = 0
                            suggestions = SuggestionEngine.suggestions(for: text, browser: browser)
                        }
                        // Exchange rates that have just arrived: the conversion typed gets its answer.
                        .onChange(of: CurrencyRates.shared.revision) {
                            suggestions = SuggestionEngine.suggestions(for: text, browser: browser)
                        }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                if !suggestions.isEmpty {
                    Divider().opacity(0.5)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                                SuggestionRow(suggestion: suggestion, selected: index == selection)
                                    .onTapGesture { run(suggestion) }
                                    .onHover { if $0 { selection = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.stroke, lineWidth: focused ? 1.5 : 1))
            .shadow(color: Theme.shadow.opacity(0.35), radius: 30, y: 12)
            .padding(.top, 110)
            .padding(.leading, leadingInset)
        }
    }

    private var placeholder: String {
        switch request.mode {
        case .currentTab: "Rechercher ou saisir une adresse"
        case .newTab: browser.isPrivate ? "Nouvel onglet privé — rechercher ou saisir une adresse" : "Nouvel onglet — rechercher ou saisir une adresse"
        }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func commit(_ suggestions: [Suggestion]) {
        if suggestions.indices.contains(selection) {
            run(suggestions[selection])
        } else if !text.isEmpty {
            browser.navigate(text, mode: request.mode)
            dismiss()
        }
    }

    private func run(_ suggestion: Suggestion) {
        dismiss()
        switch suggestion.kind {
        case .go(let url): browser.open(url, mode: request.mode)
        case .search(let query):
            if let url = AppSettings.shared.searchURL(for: query) { browser.open(url, mode: request.mode) }
        case .switchTo(let tab): browser.select(tab)
        case .download(let item): DownloadManager.shared.reveal(item)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            browser.showToast("doc.on.doc", "« \(text) » copié")
        case .action(let action): action()
        }
    }

    private func dismiss() {
        browser.commandBar = nil
        if let webView = browser.selectedTab?.webView { webView.window?.makeFirstResponder(webView) }
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                .frame(width: 18)
            Text(suggestion.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Text(suggestion.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accentSoft : .clear))
        .contentShape(Rectangle())
    }
}
