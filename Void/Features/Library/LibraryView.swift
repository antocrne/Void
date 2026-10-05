import SwiftUI

/// History, bookmarks and downloads in one window (⌘Y, ⌥⌘B, ⌥⌘L).
struct LibraryView: View {
    @Environment(BrowserModel.self) private var browser
    @State private var query = ""
    @State private var history: [HistoryEntry] = []
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $browser.librarySection) {
                    ForEach(LibrarySection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                Spacer()
                TextField("Rechercher", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(12)
            Divider()
            switch browser.librarySection {
            case .history: historyList
            case .bookmarks: bookmarkList
            case .downloads: downloadList
            }
        }
        .frame(minWidth: 620, minHeight: 400)
        .tint(Theme.accent)
        .onAppear(perform: reloadHistory)
        .onChange(of: query) { reloadHistory() }
        .onChange(of: browser.librarySection) { reloadHistory() }
    }

    private func reloadHistory() {
        history = query.isEmpty ? HistoryStore.shared.recent(limit: 500) : HistoryStore.shared.search(query, limit: 500)
    }

    /// In the frontmost normal window, reopening the main one if it was closed.
    private func open(_ url: URL) {
        BrowserWindows.shared.normalTarget.openExternal(url)
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            List(history) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title).lineLimit(1)
                        Text(entry.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(entry.lastVisit, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(entry.url) }
                .contextMenu {
                    Button("Ouvrir dans un nouvel onglet") { open(entry.url) }
                    Button("Supprimer de l'historique") { HistoryStore.shared.delete(entry); reloadHistory() }
                }
            }
            HStack {
                Text("\(history.count) pages").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Effacer l'historique…") { confirmingClear = true }
                    .confirmationDialog("Effacer tout l'historique ?", isPresented: $confirmingClear) {
                        Button("Effacer l'historique", role: .destructive) {
                            HistoryStore.shared.clear()
                            reloadHistory()
                        }
                    } message: {
                        Text("Toutes les pages visitées sont retirées de l'historique. Les cookies et les favoris sont conservés.")
                    }
            }
            .padding(10)
        }
    }

    private var bookmarkList: some View {
        let items = query.isEmpty ? BookmarkStore.shared.bookmarks : BookmarkStore.shared.search(query, limit: 1000)
        return List(items) { bookmark in
            HStack {
                Image(systemName: "star.fill").foregroundStyle(Theme.accent).font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.title).lineLimit(1)
                    Text(bookmark.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let folder = bookmark.folder { Text(folder).font(.caption).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(bookmark.url) }
            .contextMenu {
                Button("Ouvrir dans un nouvel onglet") { open(bookmark.url) }
                Button("Supprimer", role: .destructive) { BookmarkStore.shared.remove(bookmark) }
            }
        }
        .overlay { if items.isEmpty { Text("Aucun favori — ⌘D sur une page pour l'ajouter").foregroundStyle(.secondary) } }
    }

    private var downloadList: some View {
        let manager = DownloadManager.shared
        let items = query.isEmpty ? manager.history : manager.history.filter { $0.filename.localizedCaseInsensitiveContains(query) }
        return VStack(spacing: 0) {
            List(items) { item in
                DownloadRow(item: item)
            }
            .overlay { if items.isEmpty { Text("Aucun téléchargement").foregroundStyle(.secondary) } }
            HStack {
                Spacer()
                Button("Effacer la liste") { manager.clearFinished() }
            }
            .padding(10)
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        let manager = DownloadManager.shared
        HStack(spacing: 10) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename).lineLimit(1)
                switch item.state {
                case .running, .paused:
                    Group {
                        if item.totalBytes > 0 { ProgressView(value: item.progress) } else { ProgressView().progressViewStyle(.linear) }
                    }
                    .controlSize(.small)
                    .opacity(item.state == .paused ? 0.5 : 1)
                    Text(item.state == .paused ? item.pausedText : item.statusText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                case .finished: Text(item.finishedText).font(.caption).foregroundStyle(.secondary)
                case .cancelled: Text("Annulé").font(.caption).foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(item.canResume ? "Interrompu · \(reason)" : reason).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            Spacer()
            switch item.state {
            case .running, .paused:
                if item.state == .paused {
                    Button { manager.resume(item) } label: { Image(systemName: "play.circle") }
                        .help("Reprendre")
                        .disabled(!item.canResume)
                } else if item.canPause {
                    Button { manager.pause(item) } label: { Image(systemName: "pause.circle") }
                        .help("Mettre en pause")
                }
                Button("Annuler") { manager.cancel(item) }
            default:
                if item.canResume {
                    Button("Reprendre") { manager.resume(item) }
                } else if item.state == .finished, item.destination != nil {
                    Button { manager.reveal(item) } label: { Image(systemName: "magnifyingglass") }
                        .help("Afficher dans le Finder")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { manager.open(item) }
        .contextMenu {
            switch item.state {
            case .running, .paused:
                if item.state == .paused {
                    Button("Reprendre") { manager.resume(item) }.disabled(!item.canResume)
                } else if item.canPause {
                    Button("Mettre en pause") { manager.pause(item) }
                }
                Button("Annuler") { manager.cancel(item) }
            case .finished:
                Button("Ouvrir") { manager.open(item) }
                Button("Afficher dans le Finder") { manager.reveal(item) }
                Button("Déplacer vers…") { manager.move(item) }
            default:
                if item.canResume { Button("Reprendre") { manager.resume(item) } }
            }
            if let source = item.sourceURL, ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
                Divider()
                Button("Copier l'adresse du fichier") { Clipboard.copy(source.absoluteString) }
            }
        }
    }
}
