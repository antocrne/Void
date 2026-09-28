import Foundation

/// On-disk session: spaces, pinned tabs and (optionally) regular tabs.
struct SavedState: Codable {
    var version = 1
    var currentSpaceID: UUID
    var spaces: [SavedSpace]
}

struct SavedSpace: Codable {
    var id: UUID
    var name: String
    var icon: String
    var pinned: [SavedTab]
    var tabs: [SavedTab]
    var selectedTabID: UUID?
}

struct SavedTab: Codable {
    var id: UUID
    var url: URL?
    var title: String
    var favicon: Data?
}

enum StateStore {
    /// ~/Library/Application Support/Void
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Void", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var fileURL: URL { directory.appendingPathComponent("session.json") }

    static func load() -> SavedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    static func save(_ state: SavedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
