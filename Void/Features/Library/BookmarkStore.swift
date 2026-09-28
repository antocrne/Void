import Foundation
import Observation

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    var folder: String?
    var added = Date()
}

/// Bookmarks, stored as JSON in Application Support.
@MainActor @Observable
final class BookmarkStore {
    static let shared = BookmarkStore()
    private(set) var bookmarks: [Bookmark] = []
    @ObservationIgnored private let fileURL = StateStore.directory.appendingPathComponent("bookmarks.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = decoded
        }
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    /// ⌘D: adds or removes the current page. Returns true if it's now bookmarked.
    @discardableResult
    func toggle(url: URL, title: String) -> Bool {
        if let i = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: i)
            save()
            return false
        }
        bookmarks.insert(Bookmark(title: title.isEmpty ? (url.host() ?? url.absoluteString) : title, url: url), at: 0)
        save()
        return true
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    func search(_ text: String, limit: Int = 5) -> [Bookmark] {
        let q = text.lowercased()
        guard !q.isEmpty else { return [] }
        return Array(bookmarks.filter { $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q) }.prefix(limit))
    }

    /// Adds imported bookmarks, skipping URLs already present. Returns the number added.
    @discardableResult
    func importBookmarks(_ items: [Bookmark]) -> Int {
        var known = Set(bookmarks.map(\.url))
        var added = 0
        for item in items where !known.contains(item.url) {
            bookmarks.append(item)
            known.insert(item.url)
            added += 1
        }
        save()
        return added
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) { try? data.write(to: fileURL, options: .atomic) }
    }
}
