import AppKit
import WebKit
import Observation

struct InstalledExtension: Codable, Identifiable, Hashable {
    var id: String          // stable uniqueIdentifier → keeps the extension's storage across launches
    var path: String        // unpacked folder (Void's own copy; older installs may point elsewhere)
    /// Chrome Web Store ID, when it came from the store or from another Chromium browser.
    var chromeID: String?
}

/// Web extensions through WKWebExtension (macOS 15.4+), optional (Settings → Extensions):
/// the same WebExtensions API as Chrome's (`chrome.*` and `browser.*`), so Chrome extensions
/// run as they are. They install from the Chrome Web Store (a link, or the page's button in the
/// address field), a .crx / .zip file or a folder, or from Chrome, Brave, Edge or Arc; Void keeps
/// its own copy. Void's tabs and windows are exposed to them (ExtensionBridge).
/// Not supported: native messaging, keyboard commands, the Chrome-only APIs WebKit lacks.
@available(macOS 15.4, *)
@MainActor @Observable
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionManager()
    /// The manager while extensions run: the model's events go nowhere otherwise (and, with
    /// extensions off, never create it).
    static var running: ExtensionManager? { isRunning ? shared : nil }
    @ObservationIgnored private static var isRunning = false

    @ObservationIgnored let controller = WKWebExtensionController(configuration: .default())
    @ObservationIgnored private(set) lazy var bridge = ExtensionBridge(controller: controller)
    private(set) var contexts: [WKWebExtensionContext] = []
    private(set) var isStarted = false
    /// An install in progress (store download, unpacking): its name, for the UI.
    private(set) var installing: String?
    var lastError: String?
    /// Bumped when an extension's toolbar action changes (icon, badge, title).
    private(set) var actionsRevision = 0

    @ObservationIgnored private let listURL = StateStore.directory.appendingPathComponent("extensions.json")
    /// Void's copies of the installed extensions, one folder per install.
    @ObservationIgnored static let folder = StateStore.directory.appendingPathComponent("Extensions", isDirectory: true)
    /// Per window: the toolbar button popups hang from.
    @ObservationIgnored private var anchors: [ObjectIdentifier: WeakView] = [:]

    private override init() {
        super.init()
        controller.delegate = self
    }

    private var installed: [InstalledExtension] {
        get { (try? JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: listURL))) ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: listURL, options: .atomic) } }
    }

    func record(for context: WKWebExtensionContext) -> InstalledExtension? {
        installed.first { $0.id == context.uniqueIdentifier }
    }

    // MARK: - On / off

    /// Loads the installed extensions (at launch, or when they are switched on).
    func start() {
        guard !isStarted else { return }
        isStarted = true
        Self.isRunning = true
        for item in installed where !contexts.contains(where: { $0.uniqueIdentifier == item.id }) {
            Task {
                do { try await load(URL(fileURLWithPath: item.path), identifier: item.id) } catch {
                    lastError = "\(URL(fileURLWithPath: item.path).lastPathComponent) : \(error.localizedDescription)"
                }
            }
        }
    }

    /// Switched off: every extension stops (content scripts, background pages, popups).
    func stop() {
        guard isStarted else { return }
        for context in contexts { try? controller.unload(context) }
        contexts = []
        isStarted = false
        Self.isRunning = false
    }

    // MARK: - Installing

    /// A folder, a .zip or a .crx chosen by the user.
    func install(from url: URL) async {
        await runInstall(url.deletingPathExtension().lastPathComponent) {
            let destination = Self.newFolder()
            if url.hasDirectoryPath {
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: destination)
            } else {
                try await Self.unpack(Data(contentsOf: url), to: destination)
            }
            return try await self.add(destination, chromeID: nil)
        }
    }

    /// A Chrome Web Store link or extension ID.
    func installFromWebStore(_ input: String) async {
        guard let id = ChromeExtensions.extensionID(from: input) else {
            lastError = ChromeExtensions.Failure.notAnExtensionLink.localizedDescription
            return
        }
        await runInstall("Chrome Web Store") {
            let data = try await ChromeExtensions.downloadFromWebStore(id: id)
            let destination = Self.newFolder()
            try await Self.unpack(data, to: destination)
            return try await self.add(destination, chromeID: id)
        }
    }

    /// An extension installed in another Chromium browser: copied, the original is left alone.
    func importExtension(_ item: ChromeExtensions.Installed) async {
        await runInstall(item.name) {
            let destination = Self.newFolder()
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: item.folder, to: destination)
            // Chrome's integrity data for its own copy: meaningless here.
            try? FileManager.default.removeItem(at: destination.appendingPathComponent("_metadata"))
            return try await self.add(destination, chromeID: item.id)
        }
    }

    func isInstalled(chromeID: String) -> Bool {
        installed.contains { $0.chromeID == chromeID }
    }

    private func runInstall(_ name: String, _ work: () async throws -> WKWebExtensionContext) async {
        installing = name
        defer { installing = nil }
        do {
            let context = try await work()
            lastError = nil
            let title = context.webExtension.displayName ?? name
            BrowserWindows.shared.active.showToast("puzzlepiece.extension", "« \(title) » ajoutée")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Loads the unpacked extension in `folder`; on failure the folder goes. A new version of an
    /// extension already installed from Chrome replaces it (and keeps its data).
    private func add(_ folder: URL, chromeID: String?) async throws -> WKWebExtensionContext {
        let previous = chromeID.flatMap { id in installed.first { $0.chromeID == id } }
        if let previous, let old = contexts.first(where: { $0.uniqueIdentifier == previous.id }) {
            try? controller.unload(old)
            contexts.removeAll { $0 === old }
        }
        let id = previous?.id ?? UUID().uuidString
        do {
            let context = try await load(folder, identifier: id)
            if let previous {
                installed.removeAll { $0.id == previous.id }
                removeCopy(previous.path)
            }
            installed.append(InstalledExtension(id: id, path: folder.path, chromeID: chromeID))
            // Installing switches extensions on (they would do nothing otherwise); only now, so
            // that starting doesn't load the version being replaced.
            if !AppSettings.shared.extensionsEnabled { AppSettings.shared.extensionsEnabled = true }
            return context
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if let previous { _ = try? await load(URL(fileURLWithPath: previous.path), identifier: previous.id) }
            throw error
        }
    }

    func uninstall(_ context: WKWebExtensionContext) {
        try? controller.unload(context)
        contexts.removeAll { $0 === context }
        if let record = record(for: context) { removeCopy(record.path) }
        installed.removeAll { $0.id == context.uniqueIdentifier }
        // Its storage, cookies and the like.
        controller.fetchDataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes, for: context) { [controller] record in
            guard let record else { return }
            controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [record]) {}
        }
    }

    /// Only Void's own copies are deleted, never a folder the user pointed an older Void at.
    private func removeCopy(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix(Self.folder.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func newFolder() -> URL { folder.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    private static func unpack(_ data: Data, to destination: URL) async throws {
        let zip = try ChromeExtensions.zipData(fromCRX: data)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("void-extension-\(UUID().uuidString).zip")
        try zip.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await ChromeExtensions.unzip(temporary, to: destination)
    }

    @discardableResult
    private func load(_ url: URL, identifier: String) async throws -> WKWebExtensionContext {
        let ext = try await WKWebExtension(resourceBaseURL: url)
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = identifier
        context.isInspectable = true
        // Private windows: off unless allowed in Settings → Extensions.
        context.hasAccessToPrivateData = AppSettings.shared.extensionsInPrivate
        // Installing = consenting to what the manifest asks for (as Chrome does).
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
        contexts.append(context)
        return context
    }

    func applyPrivateAccess() {
        for context in contexts { context.hasAccessToPrivateData = AppSettings.shared.extensionsInPrivate }
    }

    // MARK: - Toolbar

    func action(_ context: WKWebExtensionContext, in browser: BrowserModel) -> WKWebExtension.Action? {
        context.action(for: browser.selectedTab.map(bridge.tab))
    }

    /// Toolbar click on an extension: its popup, or its `action.onClicked`.
    func performAction(_ context: WKWebExtensionContext, in browser: BrowserModel) {
        context.performAction(for: browser.selectedTab.map(bridge.tab))
    }

    func openOptions(_ context: WKWebExtensionContext) {
        guard let url = context.optionsPageURL else { return }
        let browser = BrowserWindows.shared.normalTarget
        if let open = browser.extensionTabs.first(where: { $0.url == url }) {
            browser.select(open)
        } else {
            browser.openTab(url: url)
        }
    }

    /// Items of the page's context menu added by extensions (chrome.contextMenus).
    func menuItems(for tab: Tab) -> [NSMenuItem] {
        contexts.flatMap { $0.menuItems(for: bridge.tab(tab)) }
    }

    /// Extension pages (options, popups opened as tabs) need the extension's own configuration.
    func configuration(for url: URL?) -> WKWebViewConfiguration? {
        guard let url, url.scheme == "webkit-extension" else { return nil }
        return controller.extensionContext(for: url)?.webViewConfiguration
    }

    func setAnchor(_ view: NSView?, for browser: BrowserModel) {
        anchors[ObjectIdentifier(browser)] = view.map(WeakView.init)
    }

    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        bridge.openWindows
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        bridge.window(BrowserWindows.shared.active)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        let parent = ExtensionBridge.tab(configuration.parentTab)
        let browser = ExtensionBridge.browser(configuration.window) ?? parent?.browser ?? BrowserWindows.shared.active
        let tab = browser.openTab(url: configuration.url, background: !configuration.shouldBeActive,
                                  after: parent?.browser === browser ? parent : nil)
        // `index` counts every tab of the window (see extensionTabs): keep it within the tab's space.
        if let space = tab.space, let offset = browser.extensionTabs.firstIndex(where: { $0 === space.allTabs.first }) {
            let target = configuration.index - offset - space.pinned.count
            if space.tabs.indices.contains(target) { browser.moveTab(tab, to: target) }
        }
        if configuration.shouldBePinned, browser.managesSpaces { browser.togglePin(tab) }
        if configuration.shouldBeMuted { WebKitSPI.setPageMuted(tab.ensureWebView(), true) }
        completionHandler(bridge.tab(tab), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void) {
        let windows = BrowserWindows.shared
        let browser = configuration.shouldBePrivate ? windows.openPrivateWindow() : windows.openNormalWindow()
        for url in configuration.tabURLs { browser.openTab(url: url) }
        // Tabs moved to the new window: reopened there (a web view can't change windows' storage).
        for moved in configuration.tabs.compactMap(ExtensionBridge.tab) {
            if let url = moved.url { browser.openTab(url: url) }
            moved.browser?.close(moved, force: true)
        }
        let frame = configuration.frame
        if !frame.isNull, !frame.width.isNaN, !frame.height.isNaN {
            bridge.window(browser).setFrame(frame, for: extensionContext) { _ in }
        }
        if !configuration.shouldBeFocused { windows.active.window?.makeKeyAndOrderFront(nil) }
        completionHandler(bridge.window(browser), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Error?) -> Void) {
        openOptions(extensionContext)
        completionHandler(nil)
    }

    /// chrome.permissions.request(): asked, as Chrome does.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let list = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        completionHandler(confirm(extensionContext, asks: "des autorisations supplémentaires : \(list)") ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", ")
        completionHandler(confirm(extensionContext, asks: "l'accès à \(hosts)") ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let sites = matchPatterns.map(\.description).sorted().joined(separator: ", ")
        completionHandler(confirm(extensionContext, asks: "l'accès à \(sites)") ? matchPatterns : [], nil)
    }

    private func confirm(_ context: WKWebExtensionContext, asks what: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "« \(context.webExtension.displayName ?? "Une extension") » demande \(what)."
        alert.addButton(withTitle: "Autoriser")
        alert.addButton(withTitle: "Refuser")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionsRevision &+= 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        let browser = ExtensionBridge.tab(action.associatedTab)?.browser ?? BrowserWindows.shared.active
        guard let popover = action.popupPopover else { return completionHandler(nil) }
        if let anchor = anchors[ObjectIdentifier(browser)]?.view, anchor.window != nil, !anchor.visibleRect.isEmpty {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = browser.window?.contentView {
            // The button isn't shown (tabs hidden at the edge): under the window's top-right corner.
            let corner = NSRect(x: content.bounds.maxX - 40, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
        completionHandler(nil)
    }
}
