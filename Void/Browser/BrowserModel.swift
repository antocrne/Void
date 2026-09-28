import AppKit
import SwiftUI
import WebKit
import Observation

enum CommandBarMode { case currentTab, newTab }

struct CommandBarRequest: Identifiable, Equatable {
    let id = UUID()
    var mode: CommandBarMode
    var text: String
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var message: String
}

struct PasswordSavePrompt: Identifiable {
    let id = UUID()
    let host: String
    let username: String
    let password: String
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case bookmarks, history, downloads
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bookmarks: "Favoris"
        case .history: "Historique"
        case .downloads: "Téléchargements"
        }
    }
}

/// The state of one browser window: spaces, tabs, selection and transient UI.
/// `shared` is the main window, whose session is saved; ⌘N and ⌘⇧N windows get their own model
/// (see BrowserWindows).
@MainActor @Observable
final class BrowserModel {
    enum Kind {
        /// The main window: spaces, pinned tabs, saved session.
        case main
        /// Another normal window (⌘N): same spaces and storage, its own tabs, not saved.
        case secondary
        /// Private window (⌘⇧N): one ephemeral store for all its tabs, nothing saved.
        case privateWindow
    }

    static let shared = BrowserModel(kind: .main)

    let kind: Kind
    var isPrivate: Bool { kind == .privateWindow }
    /// Pinned tabs and space management live in the main window only.
    var managesSpaces: Bool { kind == .main }

    var spaces: [Space] = [] {
        didSet { spaces.forEach { $0.browser = self } }
    }
    var currentSpaceID: UUID
    var spaceTransitionEdge: Edge = .trailing

    var commandBar: CommandBarRequest?
    var findBarVisible = false
    var toast: Toast?
    var passwordPrompt: PasswordSavePrompt?
    var librarySection: LibrarySection = .history
    var isPickingElement = false

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var openWindowAction: ((String) -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    @ObservationIgnored private var closedTabs: [(url: URL, spaceID: UUID)] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    /// Disables persistence and history (used by the self-test).
    @ObservationIgnored var isEphemeralSession = false

    /// Inactivity after which a tab is put to sleep (Settings → Onglets).
    static var tabSleepDelay: TimeInterval = 30 * 60

    /// A window other than the main one. `mirroring`: the spaces to show (same identifiers,
    /// hence the same cookies and logins) in a new normal window.
    init(kind: Kind, mirroring source: BrowserModel? = nil) {
        self.kind = kind
        switch kind {
        case .privateWindow:
            let space = Space(name: "Navigation privée", icon: "eye.slash", isEphemeral: true)
            currentSpaceID = space.id
            spaces = [space]
            isEphemeralSession = true
            space.browser = self
            return
        case .secondary:
            let source = source ?? .shared
            let mirrored = source.spaces.map { Space(id: $0.id, name: $0.name, icon: $0.icon) }
            currentSpaceID = source.currentSpaceID
            spaces = mirrored
            isEphemeralSession = source.isEphemeralSession   // true only during the self-test
            mirrored.forEach { $0.browser = self }
            return
        case .main:
            break
        }
        let fallback = Space(name: "Personnel", icon: "circle")
        currentSpaceID = fallback.id
        #if DEBUG
        if SelfTestRunner.isRequested {
            // The self-test never reads or writes the user's session.
            isEphemeralSession = true
            spaces = [fallback]
            fallback.browser = self
            return
        }
        #endif
        if let saved = StateStore.load(), !saved.spaces.isEmpty {
            restore(saved)
        } else {
            spaces = [fallback, Space(name: "Travail", icon: "briefcase")]
            currentSpaceID = fallback.id
        }
        // Property observers don't run during init.
        spaces.forEach { $0.browser = self }
    }

    // MARK: - Derived state

    var currentSpace: Space { spaces.first { $0.id == currentSpaceID } ?? spaces[0] }
    var selectedTab: Tab? { currentSpace.selectedTab }
    var allTabs: [Tab] { spaces.flatMap(\.allTabs) }

    /// Tabs whose web view must stay attached to the window even when not selected,
    /// so that video keeps playing and PiP keeps working (see WebHost).
    var keepAliveTabs: [Tab] {
        allTabs.filter { $0.webView != nil && !$0.isInFloatingPlayer && ($0.isPlayingVideo || $0.isInPiP || $0.isAudible) }
    }

    func tab(for webView: WKWebView) -> Tab? { (webView as? VoidWebView)?.tab }

    // MARK: - Tabs

    /// Every tab of a private window is private (⌘T, links, pop-ups alike).
    @discardableResult
    func openTab(url: URL?, in space: Space? = nil, background: Bool = false,
                 after anchor: Tab? = nil, popupConfiguration: WKWebViewConfiguration? = nil) -> Tab {
        let space = space ?? anchor?.space ?? currentSpace
        let tab = Tab(url: url, isPrivate: isPrivate, popupConfiguration: popupConfiguration)
        tab.space = space
        withAnimation(Theme.spring) {
            if let anchor, !anchor.isPinned, let i = space.tabs.firstIndex(where: { $0 === anchor }) {
                space.tabs.insert(tab, at: i + 1)
            } else if let anchor, anchor.isPinned {
                space.tabs.insert(tab, at: 0)
            } else {
                space.tabs.append(tab)
            }
        }
        if background {
            // Background tabs still start loading so they're ready when selected.
            if popupConfiguration == nil, url != nil { tab.ensureWebView() }
        } else {
            select(tab)
        }
        setNeedsSave()
        return tab
    }

    func select(_ tab: Tab) {
        guard let space = tab.space else { return }
        let previous = selectedTab
        if space.id != currentSpaceID { currentSpaceID = space.id }
        withAnimation(Theme.spring) { space.selectedTabID = tab.id }
        // Inactivity counts from the moment a tab stops being shown.
        previous?.lastAccess = Date()
        tab.lastAccess = Date()
        tab.ensureWebView()
        findBarVisible = false
        if previous !== tab { PiPController.shared.selectionChanged(from: previous, to: tab) }
        setNeedsSave()
    }

    func close(_ tab: Tab, force: Bool = false) {
        guard let space = tab.space else { return }
        if tab.isPinned && !force {
            // ⌘W on a pinned tab puts it to sleep instead of closing it.
            if tab.isInPiP { Task { await PiPController.shared.exit(tab) } }
            let wasSelected = space.selectedTabID == tab.id
            if wasSelected { selectNeighbor(of: tab, in: space) }
            tab.sleep()
            showToast("moon.zzz", "Onglet épinglé mis en veille")
            return
        }
        if tab.isInFloatingPlayer { FloatingPlayer.shared.close() }
        if tab.isInPiP, let wv = tab.webView { PiPController.shared.forceExit(wv) }
        if let url = tab.url { closedTabs.append((url, space.id)) }
        if closedTabs.count > 30 { closedTabs.removeFirst() }
        if space.selectedTabID == tab.id { selectNeighbor(of: tab, in: space) }
        withAnimation(Theme.spring) {
            space.tabs.removeAll { $0 === tab }
            space.pinned.removeAll { $0 === tab }
        }
        tab.isPinned = false
        tab.sleep()
        setNeedsSave()
    }

    private func selectNeighbor(of tab: Tab, in space: Space) {
        let list = space.tabs
        if let i = list.firstIndex(where: { $0 === tab }) {
            let candidates = list.enumerated().filter { $0.element !== tab }
            if let next = candidates.first(where: { $0.offset > i }) ?? candidates.last {
                select(next.element)
                return
            }
        }
        if let pinnedAwake = space.pinned.first(where: { $0 !== tab && !$0.isAsleep }) {
            select(pinnedAwake)
            return
        }
        let previous = space.selectedTab
        withAnimation(Theme.spring) { space.selectedTabID = nil }
        PiPController.shared.selectionChanged(from: previous, to: nil)
    }

    func closeCurrentTab() {
        if let tab = selectedTab { close(tab) }
    }

    func reopenClosedTab() {
        guard let last = closedTabs.popLast() else { return }
        let space = spaces.first { $0.id == last.spaceID } ?? currentSpace
        openTab(url: last.url, in: space)
    }

    func togglePin(_ tab: Tab) {
        guard let space = tab.space, managesSpaces, !tab.isPrivate else { return }
        withAnimation(Theme.spring) {
            if tab.isPinned {
                space.pinned.removeAll { $0 === tab }
                tab.isPinned = false
                space.tabs.insert(tab, at: 0)
            } else {
                space.tabs.removeAll { $0 === tab }
                tab.isPinned = true
                space.pinned.append(tab)
            }
        }
        setNeedsSave()
    }

    func movePinned(from source: IndexSet, to destination: Int) {
        currentSpace.pinned.move(fromOffsets: source, toOffset: destination)
        setNeedsSave()
    }

    func moveTabs(from source: IndexSet, to destination: Int) {
        currentSpace.tabs.move(fromOffsets: source, toOffset: destination)
        setNeedsSave()
    }

    /// ⌘1…⌘8 select the nth tab, ⌘9 the last one (pinned tabs come first).
    func selectTab(number: Int) {
        let list = currentSpace.allTabs
        guard !list.isEmpty else { return }
        let index = number == 9 ? list.count - 1 : number - 1
        if list.indices.contains(index) { select(list[index]) }
    }

    func selectAdjacentTab(_ delta: Int) {
        let list = currentSpace.allTabs
        guard !list.isEmpty else { return }
        guard let current = selectedTab, let i = list.firstIndex(where: { $0 === current }) else {
            select(list[0]); return
        }
        select(list[(i + delta + list.count) % list.count])
    }

    // MARK: - Navigation

    func showCommandBar(_ mode: CommandBarMode) {
        let text = mode == .currentTab ? (selectedTab?.url?.absoluteString ?? "") : ""
        commandBar = CommandBarRequest(mode: mode, text: text)
    }

    func navigate(_ input: String, mode: CommandBarMode) {
        guard let url = URLResolver.url(from: input) ?? AppSettings.shared.searchURL(for: input) else { return }
        open(url, mode: mode)
    }

    func open(_ url: URL, mode: CommandBarMode) {
        switch mode {
        case .currentTab:
            if let tab = selectedTab { tab.load(url) } else { openTab(url: url) }
        case .newTab:
            openTab(url: url)
        }
    }

    /// URLs opened from other apps (Void as default browser).
    func openExternal(_ url: URL) {
        openTab(url: url)
        NSApp.activate(ignoringOtherApps: true)
        if window == nil { openWindowAction?(WindowID.main) }
    }

    // MARK: - Spaces

    func switchSpace(to space: Space) {
        guard space.id != currentSpaceID else { return }
        let previous = selectedTab
        let oldIndex = spaces.firstIndex { $0.id == currentSpaceID } ?? 0
        let newIndex = spaces.firstIndex { $0.id == space.id } ?? 0
        spaceTransitionEdge = newIndex > oldIndex ? .trailing : .leading
        withAnimation(Theme.spring) { currentSpaceID = space.id }
        space.selectedTab?.ensureWebView()
        PiPController.shared.selectionChanged(from: previous, to: space.selectedTab)
        setNeedsSave()
    }

    func switchSpace(by delta: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let j = i + delta
        guard spaces.indices.contains(j) else { return }
        switchSpace(to: spaces[j])
    }

    @discardableResult
    func addSpace(name: String, icon: String) -> Space {
        precondition(managesSpaces, "Spaces are managed from the main window")
        let space = Space(name: name.isEmpty ? "Espace \(spaces.count + 1)" : name, icon: icon)
        spaces.append(space)
        switchSpace(to: space)
        setNeedsSave()
        return space
    }

    func moveSpace(from source: IndexSet, to destination: Int) {
        spaces.move(fromOffsets: source, toOffset: destination)
        setNeedsSave()
    }

    func deleteSpace(_ space: Space) {
        guard spaces.count > 1 else { return }
        // Other normal windows showing this space lose it too (its storage is about to go).
        for other in BrowserWindows.shared.all where other !== self {
            if let mirror = other.spaces.first(where: { $0.id == space.id }), other.spaces.count > 1 {
                for tab in mirror.allTabs { other.close(tab, force: true) }
                if mirror.id == other.currentSpaceID, let next = other.spaces.first(where: { $0.id != mirror.id }) { other.switchSpace(to: next) }
                other.spaces.removeAll { $0.id == mirror.id }
            }
        }
        for tab in space.allTabs { close(tab, force: true) }
        if space.id == currentSpaceID, let other = spaces.first(where: { $0.id != space.id }) { switchSpace(to: other) }
        spaces.removeAll { $0.id == space.id }
        Space.releaseStore(for: space.id)
        WKWebsiteDataStore.remove(forIdentifier: space.id) { _ in }
        setNeedsSave()
    }

    // MARK: - Toasts

    func showToast(_ symbol: String, _ message: String) {
        withAnimation(Theme.spring) { toast = Toast(symbol: symbol, message: message) }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(Theme.spring) { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    // MARK: - Automatic sleep

    /// Puts idle tabs to sleep (called every minute by BrowserWindows). The visible tab and
    /// pinned tabs are never touched; see `Tab.canAutoSleep` for the other exceptions.
    func sleepInactiveTabs(now: Date = Date()) {
        guard AppSettings.shared.sleepInactiveTabs else { return }
        let visible = selectedTab
        for space in spaces {
            for tab in space.tabs where tab !== visible && tab.canAutoSleep(idleFor: Self.tabSleepDelay, now: now) {
                Task { await tab.sleepKeepingPlace(idleFor: Self.tabSleepDelay) }
            }
        }
    }

    // MARK: - Window lifetime

    /// Called when the window closes (secondary and private windows). For a private window this
    /// destroys everything it held: web views, the in-memory store's cookies, cache and sessions,
    /// the reopen-closed-tab list and its downloads list.
    func tearDown() {
        for tab in allTabs {
            if tab.isInFloatingPlayer { FloatingPlayer.shared.close() }
            if tab.isInPiP, let wv = tab.webView { PiPController.shared.forceExit(wv) }
            tab.sleep()
        }
        if isPrivate {
            for space in spaces {
                space.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            }
            DownloadManager.shared.forget(browser: self)
        }
        closedTabs = []
        commandBar = nil
        passwordPrompt = nil
        // These SwiftUI actions reference the window's view graph, which references this model.
        openWindowAction = nil
        openSettingsAction = nil
        for space in spaces {
            space.tabs = []
            space.pinned = []
            space.selectedTabID = nil
        }
        window = nil
    }

    // MARK: - Persistence

    /// Only the main window's session is saved (other windows would overwrite it).
    private var savesSession: Bool { kind == .main && !isEphemeralSession }

    func setNeedsSave() {
        guard savesSession else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        guard savesSession else { return }
        let restoreTabs = AppSettings.shared.restoreTabs
        let saved = SavedState(currentSpaceID: currentSpaceID, spaces: spaces.map { space in
            let persistable: (Tab) -> SavedTab = { SavedTab(id: $0.id, url: $0.url, title: $0.title, favicon: $0.faviconData) }
            return SavedSpace(id: space.id, name: space.name, icon: space.icon,
                              pinned: space.pinned.map(persistable),
                              tabs: restoreTabs ? space.tabs.filter { !$0.isPrivate && $0.url != nil }.map(persistable) : [],
                              selectedTabID: space.selectedTab?.isPrivate == true ? nil : space.selectedTabID)
        })
        StateStore.save(saved)
    }

    private func restore(_ saved: SavedState) {
        spaces = saved.spaces.map { s in
            let space = Space(id: s.id, name: s.name, icon: s.icon)
            space.pinned = s.pinned.map { Tab(id: $0.id, url: $0.url, title: $0.title, isPinned: true, faviconData: $0.favicon) }
            space.tabs = s.tabs.map { Tab(id: $0.id, url: $0.url, title: $0.title, faviconData: $0.favicon) }
            space.allTabs.forEach { $0.space = space }
            space.selectedTabID = s.selectedTabID
            return space
        }
        currentSpaceID = spaces.contains { $0.id == saved.currentSpaceID } ? saved.currentSpaceID : spaces[0].id
        // Only the visible tab gets a web view at launch; the rest stays asleep.
    }
}
