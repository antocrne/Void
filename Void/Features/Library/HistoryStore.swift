import Foundation

struct HistoryEntry: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    let title: String
    let visits: Int
    let lastVisit: Date
}

/// Browsing history in ~/Library/Application Support/Void/history.sqlite.
/// Private tabs never write here.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()
    private let db: SQLiteDB?

    private init() {
        db = SQLiteDB(path: StateStore.directory.appendingPathComponent("history.sqlite").path, ownDatabase: true)
        db?.execute("""
        CREATE TABLE IF NOT EXISTS history (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
                                            visits INTEGER NOT NULL DEFAULT 1, last REAL NOT NULL)
        """)
        db?.execute("CREATE INDEX IF NOT EXISTS history_last ON history(last DESC)")
        prune()
    }

    private var lastPrune = Date.distantPast

    /// Removes the pages not visited for longer than the period chosen in Settings → Confidentialité
    /// (a year by default). Runs at launch, then at most once a day as pages are visited.
    func prune() {
        lastPrune = Date()
        let cutoff = Date().addingTimeInterval(-Double(AppSettings.shared.historyRetention.rawValue) * 86_400)
        db?.execute("DELETE FROM history WHERE last < ?", [cutoff.timeIntervalSince1970])
    }

    func record(url: URL, title: String) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        if Date().timeIntervalSince(lastPrune) > 86_400 { prune() }
        db?.execute("""
        INSERT INTO history(url, title, visits, last) VALUES(?, ?, 1, ?)
        ON CONFLICT(url) DO UPDATE SET visits = visits + 1, last = excluded.last,
            title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
        """, [url.absoluteString, title, Date().timeIntervalSince1970])
    }

    /// Last title written per URL: pages that animate their title (unread counters, tickers)
    /// would otherwise write to disk continuously.
    private var writtenTitles: [String: String] = [:]
    #if DEBUG
    private(set) var titleWrites = 0
    var journalMode: String? { db?.string("PRAGMA journal_mode") }
    #endif

    func updateTitle(url: URL, title: String) {
        let key = url.absoluteString
        guard writtenTitles[key] != title else { return }
        if writtenTitles.count > 500 { writtenTitles.removeAll() }
        writtenTitles[key] = title
        #if DEBUG
        titleWrites += 1
        #endif
        db?.execute("UPDATE history SET title = ? WHERE url = ?", [title, key])
    }

    func search(_ text: String, limit: Int = 8) -> [HistoryEntry] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recent(limit: limit) }
        let like = "%" + q.replacingOccurrences(of: "%", with: "") + "%"
        return fetch("""
        SELECT url, title, visits, last FROM history WHERE url LIKE ? OR title LIKE ?
        ORDER BY (CASE WHEN url LIKE ? THEN 0 ELSE 1 END), visits DESC, last DESC LIMIT ?
        """, [like, like, "%://" + q + "%", limit])
    }

    func recent(limit: Int = 200) -> [HistoryEntry] {
        fetch("SELECT url, title, visits, last FROM history ORDER BY last DESC LIMIT ?", [limit])
    }

    func topSites(limit: Int = 8) -> [HistoryEntry] {
        fetch("SELECT url, title, visits, last FROM history ORDER BY visits DESC, last DESC LIMIT ?", [limit])
    }

    func delete(_ entry: HistoryEntry) {
        db?.execute("DELETE FROM history WHERE url = ?", [entry.url.absoluteString])
    }

    func clear() {
        db?.execute("DELETE FROM history")
    }

    /// Merges imported entries (keeps the highest visit count and the latest date).
    func importEntries(_ entries: [HistoryEntry]) {
        db?.transaction {
            for e in entries {
                db?.execute("""
                INSERT INTO history(url, title, visits, last) VALUES(?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET visits = MAX(visits, excluded.visits), last = MAX(last, excluded.last),
                    title = CASE WHEN title = '' THEN excluded.title ELSE title END
                """, [e.url.absoluteString, e.title, e.visits, e.lastVisit.timeIntervalSince1970])
            }
            return true   // an entry that fails is skipped, the others are kept
        }
        prune()
    }

    private func fetch(_ sql: String, _ args: [Any?]) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        db?.query(sql, args) { row in
            guard let url = URL(string: row.string(0)) else { return }
            out.append(HistoryEntry(url: url, title: row.string(1), visits: Int(row.int(2)),
                                    lastVisit: Date(timeIntervalSince1970: row.double(3))))
        }
        return out
    }
}
