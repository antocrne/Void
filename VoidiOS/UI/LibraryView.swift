import SwiftUI
import QuickLook

/// History, bookmarks and downloads in one sheet.
struct LibraryView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var history: [HistoryEntry] = []
    @State private var confirmingClear = false
    @State private var previewed: URL?

    var body: some View {
        @Bindable var main = BrowserModel.shared
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $main.librarySection) {
                    ForEach(LibrarySection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch main.librarySection {
                case .history: historyList
                case .bookmarks: bookmarkList
                case .downloads: downloadList
                }
            }
            .navigationTitle(main.librarySection.label)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Rechercher")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) { clearButton(main.librarySection) }
            }
        }
        .onAppear(perform: reloadHistory)
        .onChange(of: query) { reloadHistory() }
        .onChange(of: main.librarySection) { reloadHistory() }
        .quickLookPreview($previewed)
    }

    private func reloadHistory() {
        history = query.isEmpty ? HistoryStore.shared.recent(limit: 500) : HistoryStore.shared.search(query, limit: 500)
    }

    /// In the browser on screen (a page opened from private browsing stays private).
    private func open(_ url: URL) {
        browser.openTab(url: url)
        dismiss()
    }

    @ViewBuilder
    private func clearButton(_ section: LibrarySection) -> some View {
        switch section {
        case .history:
            Button("Effacer…") { confirmingClear = true }
                .disabled(history.isEmpty)
                .confirmationDialog("Effacer tout l'historique ?", isPresented: $confirmingClear, titleVisibility: .visible) {
                    Button("Effacer l'historique", role: .destructive) {
                        HistoryStore.shared.clear()
                        reloadHistory()
                    }
                } message: {
                    Text("Toutes les pages visitées sont retirées de l'historique. Les cookies et les favoris sont conservés.")
                }
        case .downloads:
            Button("Effacer la liste") { DownloadManager.shared.clearFinished() }
        case .bookmarks:
            EmptyView()
        }
    }

    private var historyList: some View {
        List {
            ForEach(history) { entry in
                Button { open(entry.url) } label: {
                    PageRow(title: entry.title.isEmpty ? entry.url.absoluteString : entry.title, url: entry.url) {
                        Text(entry.lastVisit, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contextMenu { pageMenu(entry.url) }
            }
            .onDelete { offsets in
                offsets.map { history[$0] }.forEach(HistoryStore.shared.delete)
                reloadHistory()
            }
        }
        .listStyle(.plain)
        .overlay {
            if history.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Aucune page visitée" : "Aucun résultat", systemImage: "clock")
            }
        }
    }

    private var bookmarkList: some View {
        let items = query.isEmpty ? BookmarkStore.shared.bookmarks : BookmarkStore.shared.search(query, limit: 1000)
        return List {
            ForEach(items) { bookmark in
                Button { open(bookmark.url) } label: {
                    PageRow(title: bookmark.title, url: bookmark.url) {
                        if let folder = bookmark.folder { Text(folder).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .contextMenu { pageMenu(bookmark.url) }
            }
            .onDelete { offsets in offsets.map { items[$0] }.forEach(BookmarkStore.shared.remove) }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Aucun favori" : "Aucun résultat", systemImage: "star",
                                       description: Text(query.isEmpty ? "Menu ··· → Ajouter aux favoris sur une page." : ""))
            }
        }
    }

    private var downloadList: some View {
        let manager = DownloadManager.shared
        // Private browsing shows its own downloads only, and they aren't listed anywhere else.
        let all = browser.isPrivate ? manager.items(of: browser) : manager.history
        let items = query.isEmpty ? all : all.filter { $0.filename.localizedCaseInsensitiveContains(query) }
        return List(items) { item in
            DownloadRow(item: item) { previewed = $0 }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Aucun téléchargement", systemImage: "arrow.down.circle",
                                       description: Text("Les fichiers téléchargés se retrouvent aussi dans l'app Fichiers, dossier Void."))
            }
        }
    }

    @ViewBuilder
    private func pageMenu(_ url: URL) -> some View {
        Button { open(url) } label: { Label("Ouvrir dans un nouvel onglet", systemImage: "plus.square.on.square") }
        Button { Clipboard.copy(url.absoluteString) } label: { Label("Copier le lien", systemImage: "link") }
        ShareLink(item: url) { Label("Partager…", systemImage: "square.and.arrow.up") }
    }
}

private struct PageRow<Trailing: View>: View {
    let title: String
    let url: URL
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.primaryText).lineLimit(1)
                Text(url.host()?.voidNormalizedHost ?? url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            trailing
        }
        .contentShape(Rectangle())
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let preview: (URL) -> Void

    var body: some View {
        let manager = DownloadManager.shared
        HStack(spacing: 12) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename).lineLimit(1)
                switch item.state {
                case .running, .paused:
                    Group {
                        if item.totalBytes > 0 { ProgressView(value: item.progress) } else { ProgressView().progressViewStyle(.linear) }
                    }
                    .opacity(item.state == .paused ? 0.5 : 1)
                    Text(item.state == .paused ? item.pausedText : item.statusText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                case .finished: Text(item.finishedText).font(.caption).foregroundStyle(.secondary)
                case .cancelled: Text("Annulé").font(.caption).foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(item.canResume ? String(localized: "Interrompu · \(reason)") : reason).font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
                }
            }
            Spacer()
            switch item.state {
            case .running, .paused:
                if item.state == .paused {
                    Button { manager.resume(item) } label: { Image(systemName: "play.circle").font(.title3) }
                        .disabled(!item.canResume)
                        .accessibilityLabel("Reprendre")
                } else if item.canPause {
                    Button { manager.pause(item) } label: { Image(systemName: "pause.circle").font(.title3) }
                        .accessibilityLabel("Mettre en pause")
                }
                Button { manager.cancel(item) } label: { Image(systemName: "xmark.circle").font(.title3) }
                    .accessibilityLabel("Annuler")
            default:
                if item.canResume {
                    Button { manager.resume(item) } label: { Image(systemName: "arrow.clockwise.circle").font(.title3) }
                        .accessibilityLabel("Reprendre")
                } else if item.canRetry {
                    Button { manager.retry(item) } label: { Image(systemName: "arrow.clockwise.circle").font(.title3) }
                        .accessibilityLabel("Réessayer")
                } else if item.state == .finished, let file = item.destination {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Partager")
                }
            }
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == .finished, let file = item.destination, FileManager.default.fileExists(atPath: file.path) { preview(file) }
        }
        .contextMenu {
            switch item.state {
            case .running, .paused:
                if item.state == .paused {
                    Button { manager.resume(item) } label: { Label("Reprendre", systemImage: "play") }.disabled(!item.canResume)
                } else if item.canPause {
                    Button { manager.pause(item) } label: { Label("Mettre en pause", systemImage: "pause") }
                }
                Button(role: .destructive) { manager.cancel(item) } label: { Label("Annuler", systemImage: "xmark") }
            case .finished:
                if let file = item.destination {
                    Button { manager.move(item) } label: { Label("Enregistrer dans…", systemImage: "folder") }
                    ShareLink(item: file) { Label("Partager…", systemImage: "square.and.arrow.up") }
                }
            default:
                if item.canResume { Button { manager.resume(item) } label: { Label("Reprendre", systemImage: "arrow.clockwise") } }
                if item.canRetry {
                    Button { manager.retry(item) } label: {
                        Label(item.canResume ? "Recommencer depuis le début" : "Réessayer", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
    }
}
