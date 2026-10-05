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
    /// Two tabs shown side by side (see SplitView.swift); kept while another tab is selected.
    var split: SplitPair?
    /// Share of the page width given to the left side.
    var splitRatio = 0.5
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

    /// Deleted spaces whose store folder is still on disk.
    nonisolated private static let pendingRemovalsKey = "pendingDataStoreRemovals"

    /// Removes a deleted space's store folder. WebKit refuses while the store is in use (its web
    /// views are released a little later, and the store object may still be held): the space is
    /// then remembered and its folder removed at the next launch, before any store is created.
    static func removeStoreFromDisk(_ id: UUID) {
        var pending = Set(UserDefaults.standard.stringArray(forKey: pendingRemovalsKey) ?? [])
        pending.insert(id.uuidString)
        UserDefaults.standard.set(pending.sorted(), forKey: pendingRemovalsKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { attemptRemoval(id) }
    }

    /// At launch: the folders of spaces deleted earlier that WebKit couldn't remove then.
    /// `live`: the spaces of the restored session, never touched.
    static func removePendingStores(keeping live: Set<UUID>) {
        let pending = UserDefaults.standard.stringArray(forKey: pendingRemovalsKey) ?? []
        guard !pending.isEmpty else { return }
        // remove(forIdentifier:) answers through WebKit's main run loop, which only exists once a
        // WebKit object has been made: called first thing at launch, it crashed on a null run loop.
        _ = WKWebsiteDataStore.default()
        for id in pending.compactMap(UUID.init(uuidString:)) {
            if live.contains(id) { forgetPendingRemoval(id) } else { attemptRemoval(id) }
        }
    }

    private static func attemptRemoval(_ id: UUID) {
        WKWebsiteDataStore.remove(forIdentifier: id) { error in
            if let error {
                NSLog("[Void] stockage de l'espace %@ pas encore supprimé (nouvel essai au prochain lancement) : %@",
                      id.uuidString, error.localizedDescription)
            } else {
                forgetPendingRemoval(id)
            }
        }
    }

    nonisolated private static func forgetPendingRemoval(_ id: UUID) {
        var pending = UserDefaults.standard.stringArray(forKey: pendingRemovalsKey) ?? []
        pending.removeAll { $0 == id.uuidString }
        UserDefaults.standard.set(pending, forKey: pendingRemovalsKey)
    }

    var allTabs: [Tab] { pinned + tabs }
    var selectedTab: Tab? { allTabs.first { $0.id == selectedTabID } }

    static let iconChoices = ["circle", "briefcase", "house", "book", "graduationcap", "gamecontroller",
                              "paintpalette", "music.note", "leaf", "flame", "star", "heart",
                              "cart", "airplane", "hammer", "chevron.left.forwardslash.chevron.right"]
}
