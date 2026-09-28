import Foundation
import WebKit
import Observation

/// A separate set of tabs (Work, Home…) with its own icon and its own
/// website data store (cookies, local storage, cache).
/// A private window has a single ephemeral space whose in-memory store lives as long as the window.
@MainActor @Observable
final class Space: Identifiable {
    let id: UUID
    var name: String
    var icon: String
    var pinned: [Tab] = []
    var tabs: [Tab] = []
    var selectedTabID: UUID?
    let isEphemeral: Bool

    @ObservationIgnored weak var browser: BrowserModel?
    @ObservationIgnored private var _dataStore: WKWebsiteDataStore?

    init(id: UUID = UUID(), name: String, icon: String, isEphemeral: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isEphemeral = isEphemeral
    }

    /// Persistent stores, one per space identifier, shared by every normal window showing that
    /// space (two live stores on the same directory would conflict).
    private static var persistentStores: [UUID: WKWebsiteDataStore] = [:]

    /// Persistent, per-space storage (macOS 14+ `WKWebsiteDataStore(forIdentifier:)`),
    /// or in-memory storage for the space of a private window.
    var dataStore: WKWebsiteDataStore {
        if let _dataStore { return _dataStore }
        let store: WKWebsiteDataStore
        if isEphemeral {
            store = .nonPersistent()
        } else {
            store = Self.persistentStores[id] ?? WKWebsiteDataStore(forIdentifier: id)
            Self.persistentStores[id] = store
        }
        _dataStore = store
        return store
    }

    /// Forgets the shared persistent store of a deleted space so it can be removed from disk.
    static func releaseStore(for id: UUID) {
        persistentStores[id] = nil
    }

    var allTabs: [Tab] { pinned + tabs }
    var selectedTab: Tab? { allTabs.first { $0.id == selectedTabID } }

    static let iconChoices = ["circle", "briefcase", "house", "book", "graduationcap", "gamecontroller",
                              "paintpalette", "music.note", "leaf", "flame", "star", "heart",
                              "cart", "airplane", "hammer", "chevron.left.forwardslash.chevron.right"]
}
