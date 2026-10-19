import Foundation
import Observation

struct HistoryEntry: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    let title: String
    let visits: Int
    let lastVisit: Date
}

/// Browsing history in ~/Library/Application Support/Void/history.sqlite.
/// Private tabs never write here.
@MainActor @Observable
final class HistoryStore {
    static let shared = HistoryStore()
    @ObservationIgnored private let db: SQLiteDB?
    /// Changes when the pages listed change (a visit, a first title, a deletion): the History
    /// menu reads it to show the last pages visited.
    private(set) var revision = 0

    private init() {
        db = SQLiteDB(path: StateStore.directory.appendingPathComponent("history.sqlite").path, ownDatabase: true)
        db?.execute("""
        CREATE TABLE IF NOT EXISTS history (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
                                            visits INTEGER NOT NULL DEFAULT 1, last REAL NOT NULL)
        """)
        db?.execute("CREATE INDEX IF NOT EXISTS history_last ON history(last DESC)")
        prune()
    }

    @ObservationIgnored private var lastPrune = Date.distantPast

    /// Removes the pages not visited for longer than the period chosen in Settings → Confidentialité
    /// (a year by default). Runs at launch, then at most once a day as pages are visited.
    func prune() {
        lastPrune = Date()
        let cutoff = Date().addingTimeInterval(-Double(AppSettings.shared.historyRetention.rawValue) * 86_400)
        db?.execute("DELETE FROM history WHERE last < ?", [cutoff.timeIntervalSince1970])
        revision += 1
    }

    func record(url: URL, title: String) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        if Date().timeIntervalSince(lastPrune) > 86_400 { prune() }
        db?.execute("""
        INSERT INTO history(url, title, visits, last) VALUES(?, ?, 1, ?)
        ON CONFLICT(url) DO UPDATE SET visits = visits + 1, last = excluded.last,
            title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
        """, [url.absoluteString, title, Date().timeIntervalSince1970])
        revision += 1
    }

    /// Last title written per URL: pages that animate their title (unread counters, tickers)
    /// would otherwise write to disk continuously.
    @ObservationIgnored private var writtenTitles: [String: String] = [:]
    #if DEBUG
    @ObservationIgnored private(set) var titleWrites = 0
    var journalMode: String? { db?.string("PRAGMA journal_mode") }
    var secureDelete: String? { db?.string("PRAGMA secure_delete") }
    #endif

    func updateTitle(url: URL, title: String) {
        let key = url.absoluteString
        guard writtenTitles[key] != title else { return }
        // The History menu shows a page's first title; later changes (counters) don't rebuild it.
        if writtenTitles[key] == nil { revision += 1 }
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
        // Typed text is matched as is: % and _ aren't wildcards here.
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let like = "%" + escaped + "%"
        return fetch("""
        SELECT url, title, visits, last FROM history WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
        ORDER BY (CASE WHEN url LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END), visits DESC, last DESC LIMIT ?
        """, [like, like, "%://" + escaped + "%", limit])
    }

    func recent(limit: Int = 200) -> [HistoryEntry] {
        fetch("SELECT url, title, visits, last FROM history ORDER BY last DESC LIMIT ?", [limit])
    }

    func topSites(limit: Int = 8) -> [HistoryEntry] {
        fetch("SELECT url, title, visits, last FROM history ORDER BY visits DESC, last DESC LIMIT ?", [limit])
    }

    func delete(_ entry: HistoryEntry) {
        db?.execute("DELETE FROM history WHERE url = ?", [entry.url.absoluteString])
        revision += 1
    }

    /// « Effacer l'historique »: nothing left on disk either — the write-ahead log, which still
    /// holds the old pages until a checkpoint, is emptied, and the file is rewritten.
    func clear() {
        db?.execute("DELETE FROM history")
        db?.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db?.execute("VACUUM")
        writtenTitles.removeAll()
        revision += 1
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
