import Foundation

/// On-disk session: spaces, pinned tabs, folders of tabs and (optionally) regular tabs.
/// Decoding is tolerant (see the extensions below): a missing or unknown field, or one bad tab,
/// must never cost the whole session — website data is stored per space identifier, so losing
/// the spaces would also sign the user out of every site.
struct SavedState: Codable {
    var version = 1
    var currentSpaceID: UUID
    var spaces: [SavedSpace]
    /// Each icon once (tabs of the same site share it), by `SavedTab.faviconKey`.
    var favicons: [String: Data]? = nil
}

struct SavedSpace: Codable {
    var id: UUID
    var name: String
    var icon: String
    var pinned: [SavedTab]
    var tabs: [SavedTab]
    var selectedTabID: UUID?
    var folders: [SavedFolder] = []
}

struct SavedFolder: Codable {
    var id: UUID
    var name: String
    var isExpanded: Bool
    var tabs: [SavedTab]
}

struct SavedTab: Codable {
    var id: UUID
    var url: URL?
    var title: String
    /// Sessions written before `favicons`: the icon inline.
    var favicon: Data?
    var faviconKey: String? = nil
}

/// Decodes one element of an array, or nothing if that element is damaged.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Void's other JSON files (bookmarks, extensions, hidden elements), read as carefully as the
/// session: element by element, and a file that can't be read whole is set aside — copied next to
/// it as `<name>.corrupt-<date>.json` — before the next save writes over it.
enum TolerantJSON {
    /// The elements that could be read; [] for a missing file.
    static func array<T: Decodable>(of type: T.Type, at url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let items = try? JSONDecoder().decode([Lossy<T>].self, from: data) else {
            setAside(url)
            return []
        }
        let values = items.compactMap(\.value)
        if values.count < items.count { setAside(url) }
        return values
    }

    /// A dictionary of values, read value by value.
    static func dictionary<T: Decodable>(of type: T.Type, at url: URL) -> [String: T] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let items = try? JSONDecoder().decode([String: Lossy<T>].self, from: data) else {
            setAside(url)
            return [:]
        }
        let values = items.compactMapValues(\.value)
        if values.count < items.count { setAside(url) }
        return values
    }

    /// A copy of the file as it was: the next save may leave out what couldn't be read.
    private static func setAside(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = url.deletingPathExtension().lastPathComponent
        let copy = url.deletingLastPathComponent().appendingPathComponent("\(name).corrupt-\(stamp)-\(UUID().uuidString.prefix(4)).json")
        try? FileManager.default.copyItem(at: url, to: copy)
        NSLog("[Void] %@ illisible en partie, copie mise de côté : %@", url.lastPathComponent, copy.lastPathComponent)
    }
}

private extension KeyedDecodingContainer {
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        let items = (try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil
        return items?.compactMap(\.value) ?? []
    }
}

extension SavedState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        spaces = c.lossyArray(SavedSpace.self, forKey: .spaces)
        currentSpaceID = ((try? c.decodeIfPresent(UUID.self, forKey: .currentSpaceID)) ?? nil) ?? spaces.first?.id ?? UUID()
        favicons = (try? c.decodeIfPresent([String: Data].self, forKey: .favicons)) ?? nil
    }

    /// A tab's icon, wherever this session keeps it.
    func favicon(of tab: SavedTab) -> Data? {
        tab.favicon ?? tab.faviconKey.flatMap { favicons?[$0] }
    }

    /// Key of an icon in `favicons` (FNV-1a of its bytes).
    static func faviconKey(_ data: Data) -> String {
        var h: UInt64 = 1469598103934665603
        for byte in data { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return String(h, radix: 36)
    }
}

extension SavedSpace {
    /// Only the identifier is required: it names the space's website data store.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? String(localized: "Espace")
        icon = ((try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil) ?? "circle"
        pinned = c.lossyArray(SavedTab.self, forKey: .pinned)
        tabs = c.lossyArray(SavedTab.self, forKey: .tabs)
        selectedTabID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedTabID)) ?? nil
        folders = c.lossyArray(SavedFolder.self, forKey: .folders)
    }
}

extension SavedFolder {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? String(localized: "Dossier")
        isExpanded = ((try? c.decodeIfPresent(Bool.self, forKey: .isExpanded)) ?? nil) ?? true
        tabs = c.lossyArray(SavedTab.self, forKey: .tabs)
    }
}

extension SavedTab {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        url = (try? c.decodeIfPresent(URL.self, forKey: .url)) ?? nil
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? ""
        favicon = (try? c.decodeIfPresent(Data.self, forKey: .favicon)) ?? nil
        faviconKey = (try? c.decodeIfPresent(String.self, forKey: .faviconKey)) ?? nil
    }
}

enum StateStore {
    /// ~/Library/Application Support/Void
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Void", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Where session.json lives (the self-test points it at a temporary folder).
    static var sessionDirectory = directory

    private static var fileURL: URL { sessionDirectory.appendingPathComponent("session.json") }
    /// Copy of the last session that could be read, taken at launch.
    private static var backupURL: URL { sessionDirectory.appendingPathComponent("session.backup.json") }

    static func load() -> SavedState? {
        let fm = FileManager.default
        if let state = decode(fileURL) {
            // Known good: keep a copy to fall back on if a later write is ever damaged.
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
            return state
        }
        guard fm.fileExists(atPath: fileURL.path) else { return nil }   // first launch
        // Unreadable: set it aside (never overwrite it), then fall back on the backup.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let corrupt = sessionDirectory.appendingPathComponent("session.corrupt-\(stamp)-\(UUID().uuidString.prefix(4)).json")
        try? fm.moveItem(at: fileURL, to: corrupt)
        NSLog("[Void] session illisible, mise de côté : %@", corrupt.lastPathComponent)
        return decode(backupURL)
    }

    private static func decode(_ url: URL) -> SavedState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SavedState.self, from: data),
              !state.spaces.isEmpty else { return nil }
        return state
    }

    static func save(_ state: SavedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
