import AppKit
import SwiftUI

/// Settings → Onglets → Afficher la barre de favoris: one row above the page. Bookmarks in a
/// folder are grouped in a menu named after the folder; ⌘-click opens in a new tab.
struct BookmarksBar: View {
    @Environment(BrowserModel.self) private var browser

    private enum Entry: Identifiable {
        case bookmark(Bookmark)
        case folder(String, [Bookmark])
        var id: String {
            switch self {
            case .bookmark(let b): b.id.uuidString
            case .folder(let name, _): "folder:" + name
            }
        }
    }

    var body: some View {
        let entries = Self.entries(BookmarkStore.shared.bookmarks)
        HStack(spacing: 0) {
            if entries.isEmpty {
                Text("Aucun favori — ⌘D pour ajouter la page")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .bookmark(let bookmark): BookmarkChip(bookmark: bookmark, open: open)
                            case .folder(let name, let items): FolderMenu(name: name, items: items, open: open)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .frame(height: 28)
    }

    /// Stored order; a folder appears where its first bookmark is.
    private static func entries(_ bookmarks: [Bookmark]) -> [Entry] {
        var out: [Entry] = []
        var folderIndex: [String: Int] = [:]
        for bookmark in bookmarks {
            guard let folder = bookmark.folder, !folder.isEmpty else {
                out.append(.bookmark(bookmark))
                continue
            }
            if let i = folderIndex[folder], case .folder(let name, var items) = out[i] {
                items.append(bookmark)
                out[i] = .folder(name, items)
            } else {
                folderIndex[folder] = out.count
                out.append(.folder(folder, [bookmark]))
            }
        }
        return out
    }

    private func open(_ url: URL) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            browser.openTab(url: url, background: !flags.contains(.shift), after: browser.selectedTab)
        } else {
            browser.open(url, mode: .currentTab)
        }
    }
}

private struct BookmarkChip: View {
    let bookmark: Bookmark
    let open: (URL) -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        Button { open(bookmark.url) } label: {
            HStack(spacing: 5) {
                Text(String((bookmark.url.host()?.voidNormalizedHost ?? bookmark.title).prefix(1)).uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 13, height: 13)
                    .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(Theme.accentSoft))
                Text(bookmark.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: 180)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(bookmark.url.absoluteString)
        .contextMenu {
            Button("Ouvrir dans un nouvel onglet") { browser.openTab(url: bookmark.url, background: true, after: browser.selectedTab) }
            Button("Copier le lien") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Supprimer le favori", role: .destructive) { BookmarkStore.shared.remove(bookmark) }
        }
    }
}

private struct FolderMenu: View {
    let name: String
    let items: [Bookmark]
    let open: (URL) -> Void

    var body: some View {
        Menu {
            ForEach(items) { bookmark in
                Button(bookmark.title.isEmpty ? bookmark.url.absoluteString : bookmark.title) { open(bookmark.url) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 10.5))
                Text(name).font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.primaryText.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 5)
        .frame(height: 22)
        .help("\(items.count) favori(s)")
    }
}
