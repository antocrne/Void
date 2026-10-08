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
        case .bookmarks: String(localized: "Favoris")
        case .history: String(localized: "Historique")
        case .downloads: String(localized: "Téléchargements")
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
    /// ⌘T (« + » on iOS): the selected tab steps aside for the new-tab page and its field, and comes
    /// back if nothing is opened (Esc, ⌘W). nil when the page shows because the space has no tab.
    @ObservationIgnored weak var tabBeforeNewTabPage: Tab?
    /// Bumped by every ⌘T (or ⌘L on the new-tab page): its field takes the focus again, emptied.
    var newTabFieldRequest = 0
    /// iOS: the last request the new-tab page's field answered. Its keyboard comes up for a new
    /// tab asked for, not when the page shows because the last tab was closed (or at launch).
    @ObservationIgnored var newTabFieldAnswered = 0
    var findBarVisible = false
    /// What the find bar looked for last (⌘G repeats it).
    @ObservationIgnored var lastFindText = ""
    var toast: Toast?
    var passwordPrompt: PasswordSavePrompt?
    var librarySection: LibrarySection = .history
    /// The downloads popover, next to the downloads button (⌥⌘L).
    var showingDownloads = false
    /// Downloads buttons on screen: none (sidebar hidden) → ⌥⌘L opens the Library window instead.
    @ObservationIgnored var downloadsButtonsShown = 0
    /// First-launch personalization step shown over the main window (nil = hidden).
    var onboardingStep: Int?

    #if os(macOS)
    @ObservationIgnored weak var window: NSWindow?
    /// The window is (going) full screen: its traffic lights are gone, the bars take their place.
    var isFullScreen = false
    #endif
    @ObservationIgnored var openWindowAction: ((String) -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    @ObservationIgnored private var closedTabs: [(url: URL, spaceID: UUID)] = []
    /// Private windows: sites allowed to download, forgotten with the window (DownloadPermission).
    @ObservationIgnored var allowedDownloadHosts: Set<String> = []
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
            let space = Space(name: String(localized: "Navigation privée"), icon: "eye.slash", isEphemeral: true)
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
        let fallback = Space(name: String(localized: "Personnel"), icon: "circle")
        currentSpaceID = fallback.id
        if SingleInstance.isDuplicate {
            // Quits as soon as its links are passed on: never reads or writes the session.
            isEphemeralSession = true
            spaces = [fallback]
            fallback.browser = self
            return
        }
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
            spaces = [fallback, Space(name: String(localized: "Travail"), icon: "briefcase")]
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
        allTabs.filter { $0.webView != nil && !$0.isInFloatingPlayer && ($0.isPlayingVideo || $0.isInPiP || $0.isAudible || $0.isInCall) }
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
        ExtensionEvents.tabOpened(tab)
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
        // A tab closed meanwhile (a stale suggestion, a late callback) is never brought back: its
        // web view would load and play with no row to show or close it.
        guard !tab.isClosed, let space = tab.space, space.allTabs.contains(where: { $0 === tab }) else { return }
        let previous = selectedTab
        let shownBefore = visibleTabs
        if space.id != currentSpaceID { currentSpaceID = space.id }
        tabBeforeNewTabPage = nil
        withAnimation(Theme.spring) { space.selectedTabID = tab.id }
        // Inactivity counts from the moment a tab stops being shown.
        previous?.lastAccess = Date()
        tab.lastAccess = Date()
        tab.ensureWebView()
        findBarVisible = false
        // Moving between the two sides of a split keeps both on screen: no PiP either way.
        if previous !== tab { PiPController.shared.visibleTabsChanged(from: shownBefore, to: visibleTabs) }
        ExtensionEvents.tabActivated(tab, previous: previous)
        setNeedsSave()
    }

    /// `reselect`: false when the whole space is going (deleteSpace): no neighbour is selected,
    /// hence none is woken up.
    func close(_ tab: Tab, force: Bool = false, reselect: Bool = true) {
        // Already closed: a second ⌘W answered by the page after the first one, a late callback.
        guard !tab.isClosed, let space = tab.space else { return }
        // Side by side: the other side takes the whole page.
        let partner = leaveSplit(tab)
        if tab.isPinned && !force {
            // ⌘W on a pinned tab puts it to sleep instead of closing it.
            let wasSelected = space.selectedTabID == tab.id
            if wasSelected { selectNeighbor(of: tab, in: space, preferring: partner) }
            if tab.isInPiP || tab.isInFloatingPlayer {
                // Sleep once PiP (or the floating player) has actually been left — unless the tab
                // was shown again meanwhile (it would be left without its page).
                Task {
                    await PiPController.shared.exit(tab)
                    if tab.browser?.selectedTab !== tab { tab.sleep(force: true) }
                }
            } else {
                tab.sleep()
            }
            showToast("moon.zzz", "Onglet épinglé mis en veille")
            return
        }
        if tab.isInFloatingPlayer { FloatingPlayer.shared.close() }
        if tab.isInPiP, let wv = tab.webView { PiPController.shared.forceExit(wv) }
        if let url = tab.url { closedTabs.append((url, space.id)) }
        if closedTabs.count > 30 { closedTabs.removeFirst() }
        if reselect, space.selectedTabID == tab.id { selectNeighbor(of: tab, in: space, preferring: partner) }
        withAnimation(Theme.spring) {
            space.tabs.removeAll { $0 === tab }
            space.pinned.removeAll { $0 === tab }
        }
        ExtensionEvents.tabClosed(tab)
        tab.isClosed = true
        tab.isPinned = false
        tab.sleep(force: true)
        setNeedsSave()
    }

    /// The tab that takes the place of `tab` when it goes: the next ordinary tab (else the
    /// previous one), then an awake pinned tab. A pinned tab going makes room for an ordinary one.
    private func neighbor(of tab: Tab, in space: Space) -> Tab? {
        let list = space.tabs
        if let i = list.firstIndex(where: { $0 === tab }) {
            let candidates = list.enumerated().filter { $0.element !== tab }
            if let next = candidates.first(where: { $0.offset > i }) ?? candidates.last { return next.element }
        } else if let first = list.first(where: { $0 !== tab }) {
            return first
        }
        return space.pinned.first { $0 !== tab && !$0.isAsleep }
    }

    private func selectNeighbor(of tab: Tab, in space: Space, preferring partner: Tab? = nil) {
        let next = partner ?? neighbor(of: tab, in: space)
        guard space.id == currentSpaceID else {
            // A space in the background: only its remembered selection changes. It isn't shown,
            // and its tab isn't woken up, until the user goes there.
            space.selectedTabID = next?.id
            return
        }
        if let next {
            select(next)
            return
        }
        let previous = space.selectedTab
        withAnimation(Theme.spring) { space.selectedTabID = nil }
        PiPController.shared.selectionChanged(from: previous, to: nil)
    }

    func closeCurrentTab() {
        if let tab = selectedTab { requestClose(tab) }
    }

    /// Closing asked by the user (⌘W, a tab's cross or menu). The page is asked first, as when
    /// leaving it: one that says so (beforeunload: a message being written…) gets a "Quitter cette
    /// page ?" sheet (TabWebDelegate), and the tab stays if the user does. A pinned tab goes to
    /// sleep as before, unless `force`.
    func requestClose(_ tab: Tab, force: Bool = false) {
        if tab.isPinned && !force { close(tab); return }
        guard let webView = tab.webView, let closedAtOnce = WebKitSPI.tryClose(webView) else {
            close(tab, force: force)
            return
        }
        if closedAtOnce { close(tab, force: force); return }
        // The page answers through webViewDidClose (TabWebDelegate), which closes the tab. A page
        // whose process doesn't answer doesn't keep its tab: closed anyway, unless it is asking.
        tab.closeRequested = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak tab] in
            guard let self, let tab, !tab.isClosed, tab.closeRequested, !tab.isAskingToStay else { return }
            self.close(tab, force: force)
        }
    }

    /// Settings → Confidentialité → Effacer: "reopen closed tab" no longer brings anything back.
    func forgetClosedTabs() { closedTabs = [] }

    func reopenClosedTab() {
        guard let last = closedTabs.popLast() else { return }
        let space = spaces.first { $0.id == last.spaceID } ?? currentSpace
        openTab(url: last.url, in: space)
    }

    func togglePin(_ tab: Tab) {
        guard let space = tab.space, managesSpaces, !tab.isPrivate else { return }
        let index = extensionTabs.firstIndex { $0 === tab } ?? 0
        defer {
            ExtensionEvents.tabChanged(tab, .pinned)
            ExtensionEvents.tabMoved(tab, from: index)
        }
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

    /// Moves a tab to `index` among its space's pinned tabs, or among its ordinary tabs (drag and drop).
    func moveTab(_ tab: Tab, to index: Int) {
        guard let space = tab.space else { return }
        let before = extensionTabs.firstIndex { $0 === tab } ?? 0
        defer { ExtensionEvents.tabMoved(tab, from: before) }
        func move(in list: inout [Tab]) {
            guard let from = list.firstIndex(where: { $0 === tab }), list.indices.contains(index), from != index else { return }
            list.remove(at: from)
            list.insert(tab, at: index)
        }
        withAnimation(Theme.spring) {
            if tab.isPinned { move(in: &space.pinned) } else { move(in: &space.tabs) }
        }
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
        // A new tab is typed on the new-tab page itself, not in the floating bar over it.
        if mode == .newTab || selectedTab == nil {
            showNewTabPage()
            return
        }
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

    /// The new-tab page, its field focused. The selected tab is set aside — still loaded, like any
    /// tab not shown — until something is opened from the page, or the page is left (Esc, ⌘W).
    func showNewTabPage() {
        commandBar = nil
        findBarVisible = false
        if let tab = selectedTab {
            let shownBefore = visibleTabs
            tabBeforeNewTabPage = tab
            tab.lastAccess = Date()
            withAnimation(Theme.quick) { currentSpace.selectedTabID = nil }
            PiPController.shared.visibleTabsChanged(from: shownBefore, to: [])
        }
        newTabFieldRequest += 1
    }

    /// Esc or ⌘W on the new-tab page: back to the tab it was opened over. False when there is
    /// none (an empty space, or that tab closed meanwhile).
    @discardableResult
    func leaveNewTabPage() -> Bool {
        guard selectedTab == nil, let tab = tabBeforeNewTabPage, !tab.isClosed, tab.space?.id == currentSpaceID else { return false }
        select(tab)
        return true
    }

    /// URLs opened from other apps (Void as default browser).
    func openExternal(_ url: URL) {
        openTab(url: url)
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        // A closed SwiftUI window can outlive its closing: its being gone isn't enough.
        if kind == .main, window?.isVisible != true { openWindowAction?(WindowID.main) }
        window?.makeKeyAndOrderFront(nil)
        #else
        // Links from other apps never land in private browsing.
        BrowserWindows.shared.show(self)
        commandBar = nil
        #endif
    }

    // MARK: - Spaces

    func switchSpace(to space: Space) {
        guard space.id != currentSpaceID else { return }
        let previous = selectedTab
        let shownBefore = visibleTabs
        // Leaving the new-tab page: the space left keeps the tab it was showing before.
        if previous == nil, let aside = tabBeforeNewTabPage, !aside.isClosed, aside.space === currentSpace {
            currentSpace.selectedTabID = aside.id
        }
        tabBeforeNewTabPage = nil
        let oldIndex = spaces.firstIndex { $0.id == currentSpaceID } ?? 0
        let newIndex = spaces.firstIndex { $0.id == space.id } ?? 0
        spaceTransitionEdge = newIndex > oldIndex ? .trailing : .leading
        withAnimation(Theme.spring) { currentSpaceID = space.id }
        space.selectedTab?.ensureWebView()
        splitPartner?.ensureWebView()
        PiPController.shared.visibleTabsChanged(from: shownBefore, to: visibleTabs)
        if let shown = space.selectedTab { ExtensionEvents.tabActivated(shown, previous: previous) }
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
        let space = Space(name: name.isEmpty ? String(localized: "Espace \(spaces.count + 1)") : name, icon: icon)
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
            guard let mirror = other.spaces.first(where: { $0.id == space.id }) else { continue }
            if other.spaces.count == 1, let replacement = spaces.first(where: { $0.id != space.id }) {
                // Its only space: the window takes another one of the main window's instead.
                other.spaces.append(Space(id: replacement.id, name: replacement.name, icon: replacement.icon))
            }
            if mirror.id == other.currentSpaceID, let next = other.spaces.first(where: { $0.id != mirror.id }) { other.switchSpace(to: next) }
            for tab in mirror.allTabs { other.close(tab, force: true, reselect: false) }
            other.spaces.removeAll { $0.id == mirror.id }
        }
        // Leave the space first, then close its tabs without selecting their neighbours: none of
        // them is woken up (with the space's cookies) just before going, and the user stays where
        // they were unless it was this very space.
        if space.id == currentSpaceID, let other = spaces.first(where: { $0.id != space.id }) { switchSpace(to: other) }
        for tab in space.allTabs { close(tab, force: true, reselect: false) }
        spaces.removeAll { $0.id == space.id }
        // Its data goes now (this works while the store is still referenced)…
        space.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        // …and its folder as soon as WebKit lets go of it: at the latest, at the next launch.
        Space.releaseStore(for: space.id)
        Space.removeStoreFromDisk(space.id)
        setNeedsSave()
    }

    // MARK: - Toasts

    func showToast(_ symbol: String, _ message: LocalizedStringResource) {
        showToast(symbol, verbatim: String(localized: message))
    }

    /// A message already localized, or one that needs no translation.
    func showToast(_ symbol: String, verbatim message: String) {
        withAnimation(Theme.spring) { toast = Toast(symbol: symbol, message: message) }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(Theme.spring) { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    // MARK: - Automatic sleep

    /// Puts idle tabs to sleep (called every minute by BrowserWindows). The visible tab and
    /// pinned tabs are never touched; see `Tab.canAutoSleep` for the other exceptions.
    /// `idle`: shorter when macOS runs low on memory (see BrowserWindows).
    func sleepInactiveTabs(idleFor delay: TimeInterval? = nil, now: Date = Date()) {
        guard AppSettings.shared.sleepInactiveTabs else { return }
        let idle = delay ?? Self.tabSleepDelay
        let visible = visibleTabs
        for space in spaces {
            for tab in space.tabs where !visible.contains(where: { $0 === tab }) && tab.canAutoSleep(idleFor: idle, now: now) {
                Task { await tab.sleepKeepingPlace(idleFor: idle) }
            }
        }
    }

    /// The main window was closed (its model lives on, for when it reopens): its pages stop —
    /// no sound or video from a window that isn't there — and come back, same history, when shown again.
    func windowClosed() {
        guard kind == .main else { return }
        for tab in allTabs {
            if tab.isInFloatingPlayer { FloatingPlayer.shared.close() }
            if tab.isInPiP, let wv = tab.webView { PiPController.shared.forceExit(wv) }
            tab.sleepKeepingHistory()
        }
        commandBar = nil
        findBarVisible = false
    }

    // MARK: - Window lifetime

    /// Called when the window closes (secondary and private windows). For a private window this
    /// destroys everything it held: web views, the in-memory store's cookies, cache and sessions,
    /// the reopen-closed-tab list and its downloads list.
    func tearDown() {
        for tab in allTabs {
            tab.isClosed = true   // extensions were told by ExtensionEvents.windowClosing
            if tab.isInFloatingPlayer { FloatingPlayer.shared.close() }
            if tab.isInPiP, let wv = tab.webView { PiPController.shared.forceExit(wv) }
            tab.sleep(force: true)
        }
        if isPrivate {
            for space in spaces {
                space.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            }
            DownloadManager.shared.forget(browser: self)
        }
        closedTabs = []
        allowedDownloadHosts = []
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
        #if os(macOS)
        window = nil
        #endif
    }

    // MARK: - Persistence

    /// Only the main window's session is saved (other windows would overwrite it).
    private var savesSession: Bool { kind == .main && !isEphemeralSession }

    func setNeedsSave() {
        if kind == .main { syncMirroredSpaces() }
        guard savesSession else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        // Every page load asks: one write for a burst of them (quitting saves at once anyway).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func saveNow() {
        guard savesSession else { return }
        let restoreTabs = AppSettings.shared.restoreTabs
        var favicons: [String: Data] = [:]
        let persistable: (Tab) -> SavedTab = { tab in
            // Each icon once: tabs of the same site share it.
            let key = tab.faviconData.map { data in
                let key = SavedState.faviconKey(data)
                favicons[key] = data
                return key
            }
            return SavedTab(id: tab.id, url: tab.url, title: tab.title, favicon: nil, faviconKey: key)
        }
        var saved = SavedState(currentSpaceID: currentSpaceID, spaces: spaces.map { space in
            return SavedSpace(id: space.id, name: space.name, icon: space.icon,
                              pinned: space.pinned.map(persistable),
                              tabs: restoreTabs ? space.tabs.filter { !$0.isPrivate && $0.url != nil }.map(persistable) : [],
                              selectedTabID: space.selectedTab?.isPrivate == true ? nil : selectedID(space))
        })
        saved.favicons = favicons
        StateStore.save(saved)
    }

    /// The selected tab to save: the one set aside by the new-tab page while it is shown.
    private func selectedID(_ space: Space) -> UUID? {
        if space.selectedTabID == nil, let aside = tabBeforeNewTabPage, aside.space === space, !aside.isClosed { return aside.id }
        return space.selectedTabID
    }

    /// ⌘N windows show copies of the main window's spaces: renaming, a new icon, a new space
    /// or a new order there follows here.
    private func syncMirroredSpaces() {
        for other in BrowserWindows.shared.all where other.kind == .secondary {
            let mirrored = spaces.map { space in
                let mirror = other.spaces.first { $0.id == space.id } ?? Space(id: space.id, name: space.name, icon: space.icon)
                if mirror.name != space.name { mirror.name = space.name }
                if mirror.icon != space.icon { mirror.icon = space.icon }
                return mirror
            }
            if mirrored.map(\.id) != other.spaces.map(\.id) { other.spaces = mirrored }
        }
    }

    /// Tabs of other windows kept for the next launch (quitting with ⌘N windows open): added
    /// asleep to the main window's spaces, then saved.
    func adoptForNextLaunch(_ tabs: [Tab]) {
        for tab in tabs {
            guard let url = tab.url else { continue }
            let space = spaces.first { $0.id == tab.space?.id } ?? currentSpace
            let copy = Tab(url: url, title: tab.title, faviconData: tab.faviconData)
            copy.space = space
            space.tabs.append(copy)
        }
        saveNow()
    }

    private func restore(_ saved: SavedState) {
        spaces = saved.spaces.map { s in
            let space = Space(id: s.id, name: s.name, icon: s.icon)
            space.pinned = s.pinned.map { Tab(id: $0.id, url: $0.url, title: $0.title, isPinned: true, faviconData: saved.favicon(of: $0)) }
            space.tabs = s.tabs.map { Tab(id: $0.id, url: $0.url, title: $0.title, faviconData: saved.favicon(of: $0)) }
            space.allTabs.forEach { $0.space = space }
            space.selectedTabID = s.selectedTabID
            return space
        }
        currentSpaceID = spaces.contains { $0.id == saved.currentSpaceID } ? saved.currentSpaceID : spaces[0].id
        // Only the visible tab gets a web view at launch; the rest stays asleep.
    }
}
