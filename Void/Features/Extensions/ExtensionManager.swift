import AppKit
import WebKit
import Observation

struct InstalledExtension: Codable, Identifiable, Hashable {
    /// Stable uniqueIdentifier → keeps the extension's storage across launches. It is also the
    /// extension's `chrome.runtime.id`: the Chrome Web Store ID when there is one, since sites
    /// talk to their extension by that ID (externally_connectable — Proton's sign-in, for one).
    var id: String
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
    /// The popup shown last (self-test).
    @ObservationIgnored private(set) weak var shownPopover: NSPopover?
    @ObservationIgnored private(set) weak var shownPopupWebView: WKWebView?
    /// Per window: the toolbar button popups hang from.
    @ObservationIgnored private var anchors: [ObjectIdentifier: WeakView] = [:]

    private override init() {
        super.init()
        controller.delegate = self
    }

    /// extensions.json, read once (the toolbar asks at every redraw).
    @ObservationIgnored private var installedCache: [InstalledExtension]?
    private var installed: [InstalledExtension] {
        get {
            if let installedCache { return installedCache }
            let list = (try? JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: listURL))) ?? []
            installedCache = list
            return list
        }
        set {
            installedCache = newValue
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: listURL, options: .atomic) }
        }
    }
    /// Bumped by start() and stop(): a load begun before extensions were switched off is dropped.
    @ObservationIgnored private var runGeneration = 0

    var installedRecords: [InstalledExtension] { installed }

    func record(for context: WKWebExtensionContext) -> InstalledExtension? {
        installed.first { $0.id == context.uniqueIdentifier }
    }

    // MARK: - On / off

    /// Loads the installed extensions (at launch, or when they are switched on).
    func start() {
        guard !isStarted else { return }
        isStarted = true
        Self.isRunning = true
        runGeneration &+= 1
        let generation = runGeneration
        migrateIdentifiers()
        for item in installed where !contexts.contains(where: { $0.uniqueIdentifier == item.id }) {
            Task {
                do { try await load(URL(fileURLWithPath: item.path), identifier: item.id, generation: generation) } catch is CancellationError {
                    // Switched off (or back on) while it was loading.
                } catch {
                    lastError = "\(URL(fileURLWithPath: item.path).lastPathComponent) : \(error.localizedDescription)"
                }
            }
        }
    }

    /// Earlier installs had a random ID, which sites can't address: they take their
    /// Chrome ID (their stored data, kept under the old ID, starts over).
    private func migrateIdentifiers() {
        let records = installed
        let migrated = records.map { record in
            guard let chromeID = record.chromeID, record.id != chromeID,
                  !records.contains(where: { $0.id == chromeID }) else { return record }
            var copy = record
            copy.id = chromeID
            return copy
        }
        if migrated != records { installed = migrated }
    }

    /// Switched off: every extension stops (content scripts, background pages, popups).
    func stop() {
        guard isStarted else { return }
        runGeneration &+= 1
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

    func context(chromeID: String) -> WKWebExtensionContext? {
        guard let record = installed.first(where: { $0.chromeID == chromeID }) else { return nil }
        return contexts.first { $0.uniqueIdentifier == record.id }
    }

    static let webStoreURL = URL(string: "https://chromewebstore.google.com/category/extensions")!

    /// "Ouvrir le Store": in a normal window (the store never needs a private one).
    func openWebStore(in browser: BrowserModel? = nil) {
        let target = browser.flatMap { $0.isPrivate ? nil : $0 } ?? BrowserWindows.shared.normalTarget
        target.openTab(url: Self.webStoreURL)
        target.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        let id = previous?.id ?? chromeID.flatMap { id in installed.contains { $0.id == id } ? nil : id } ?? UUID().uuidString
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

    /// extension-shim.js in Void's copy of an extension, and the background script that loads it
    /// before the extension's own.
    private static let shimFile = "void-shim.js"
    private static let backgroundWrapperFile = "void-background.js"
    /// An empty page of the extension's own, to act as the extension (reviveBackground).
    private static let blankPageFile = "void-blank.html"

    /// Void's copy of an extension gets extension-shim.js, run first in each of its contexts: the
    /// background script, its pages (popup, options…) and its content scripts. Never another
    /// folder (an older Void may point at the user's own). Content scripts injected by the
    /// extension itself (chrome.scripting) go without.
    static func addShims(to folder: URL) {
        let fm = FileManager.default
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard folder.standardizedFileURL.path.hasPrefix(Self.folder.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: manifestURL),
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              // Always rewritten: a new Void may bring a new version.
              (try? Data(Scripts.extensionShim.utf8).write(to: folder.appendingPathComponent(shimFile))) != nil
        else { return }
        try? Data("<!doctype html><meta charset=utf-8><title>Void</title>".utf8).write(to: folder.appendingPathComponent(blankPageFile))
        var changed = false

        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, worker != backgroundWrapperFile {
                // A service worker is one file: a new one imports the shim, then the extension's.
                func literal(_ path: String) -> String {
                    let data = try? JSONSerialization.data(withJSONObject: "/" + path.drop { $0 == "/" }, options: [.fragmentsAllowed, .withoutEscapingSlashes])
                    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"/\(path)\""
                }
                let source = background["type"] as? String == "module"
                    ? "import \(literal(shimFile));\nimport \(literal(worker));\n"
                    : "importScripts(\(literal(shimFile)), \(literal(worker)));\n"
                if (try? Data(source.utf8).write(to: folder.appendingPathComponent(backgroundWrapperFile))) != nil {
                    background["service_worker"] = backgroundWrapperFile
                    changed = true
                }
            } else if var scripts = background["scripts"] as? [String], scripts.first != shimFile {
                scripts.insert(shimFile, at: 0)
                background["scripts"] = scripts
                changed = true
            }
            manifest["background"] = background
        }

        // Content scripts, in the extension's isolated world (not those running in the page's own).
        if var entries = manifest["content_scripts"] as? [[String: Any]] {
            for index in entries.indices where (entries[index]["world"] as? String)?.uppercased() != "MAIN" {
                guard var scripts = entries[index]["js"] as? [String], scripts.first != shimFile else { continue }
                scripts.insert(shimFile, at: 0)
                entries[index]["js"] = scripts
                changed = true
            }
            manifest["content_scripts"] = entries
        }

        if changed, let patched = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? patched.write(to: manifestURL, options: .atomic)
        }

        // Pages: the shim as their first script.
        let tag = "<script src=\"/\(shimFile)\"></script>"
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "_metadata" { enumerator?.skipDescendants(); continue }
            guard ["html", "htm"].contains(url.pathExtension.lowercased()),
                  let page = try? String(contentsOf: url, encoding: .utf8), !page.contains(tag) else { continue }
            // Right after <head>, or <html>, or the doctype; else at the very start.
            var insertion = page.startIndex
            for pattern in ["<head(\\s[^>]*)?>", "<html(\\s[^>]*)?>", "<!doctype[^>]*>"] {
                if let range = page.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    insertion = range.upperBound
                    break
                }
            }
            var patched = page
            patched.insert(contentsOf: tag, at: insertion)
            try? patched.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// `generation`: the start() it belongs to; nothing is loaded if extensions were switched off since.
    @discardableResult
    private func load(_ url: URL, identifier: String, generation: Int? = nil) async throws -> WKWebExtensionContext {
        Self.addShims(to: url)
        let ext = try await WKWebExtension(resourceBaseURL: url)
        if let generation, generation != runGeneration || contexts.contains(where: { $0.uniqueIdentifier == identifier }) {
            throw CancellationError()
        }
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = identifier
        // The same origin at every launch, as Chrome's chrome-extension://<id>: WebKit picks a new
        // one otherwise, and the extension's pages lose their localStorage and IndexedDB.
        if let base = URL(string: "webkit-extension://\(identifier.lowercased())/") { context.baseURL = base }
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
        watchBackground(context)
        return context
    }

    func applyPrivateAccess() {
        for context in contexts { context.hasAccessToPrivateData = AppSettings.shared.extensionsInPrivate }
    }

    // MARK: - Toolbar

    func action(_ context: WKWebExtensionContext, in browser: BrowserModel) -> WKWebExtension.Action? {
        context.action(for: browser.selectedTab.map(bridge.tab))
    }

    /// Toolbar click on an extension: its popup, or its `action.onClicked`. Its background is
    /// checked first (see watchBackground): a popup that finds no one to talk to closes itself.
    func performAction(_ context: WKWebExtensionContext, in browser: BrowserModel) {
        let tab = browser.selectedTab.map(bridge.tab)
        Task {
            if await backgroundWorkerIsLost(context) {
                await reviveBackground(context)
                for _ in 0..<20 where await backgroundWorkerIsLost(context) { try? await Task.sleep(for: .milliseconds(150)) }
            }
            context.performAction(for: tab)
        }
    }

    // MARK: - Background service worker

    /// WebKit loses the service worker of an extension loaded at launch a few seconds after
    /// starting it (it turns redundant), while still taking the background for loaded: messages
    /// from the extension's popup and content scripts then reach no one — Proton Pass's popup opens
    /// empty, finds its worker dead, reloads the extension and closes. The extension's own
    /// `runtime.reload()` brings the worker back for good: Void calls it when the worker is lost.
    private func watchBackground(_ context: WKWebExtensionContext) {
        guard Self.hasServiceWorker(context) else { return }
        Task {
            // The worker is lost about 5 s after it starts: watched for a while after that.
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(2))
                guard contexts.contains(where: { $0 === context }) else { return }
                if await backgroundWorkerIsLost(context) { return await reviveBackground(context) }
            }
        }
    }

    private static func hasServiceWorker(_ context: WKWebExtensionContext) -> Bool {
        (context.webExtension.manifest["background"] as? [String: Any])?["service_worker"] is String
    }

    /// The background page WebKit keeps for a service worker, without any worker registered.
    private func backgroundWorkerIsLost(_ context: WKWebExtensionContext) async -> Bool {
        guard Self.hasServiceWorker(context), let page = WebKitSPI.backgroundWebView(context), !page.isLoading,
              let count = try? await page.callAsyncJavaScript(
                "return (await navigator.serviceWorker.getRegistrations()).length", contentWorld: .page) as? Int
        else { return false }
        return count == 0
    }

    @ObservationIgnored private var reviving: Set<ObjectIdentifier> = []

    /// `runtime.reload()` from one of the extension's pages (a blank one of Void's, see addShims),
    /// as the extension would do itself.
    private func reviveBackground(_ context: WKWebExtensionContext) async {
        guard let configuration = context.webViewConfiguration,
              reviving.insert(ObjectIdentifier(context)).inserted else { return }
        defer { reviving.remove(ObjectIdentifier(context)) }
        NSLog("[Void] extension « %@ » : service worker perdu, rechargement", context.webExtension.displayName ?? context.uniqueIdentifier)
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.load(URLRequest(url: context.baseURL.appendingPathComponent(Self.blankPageFile)))
        for _ in 0..<30 where page.isLoading || page.url == nil { try? await Task.sleep(for: .milliseconds(100)) }
        _ = try? await page.evaluateJavaScript("browser.runtime.reload(); true")
        try? await Task.sleep(for: .seconds(1))
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

    func setAnchor(_ view: NSView, for browser: BrowserModel) {
        anchors[ObjectIdentifier(browser)] = WeakView(view)
    }

    /// Only if it is still the anchor: while the tabs move from the sidebar to the top (or back),
    /// the new button can arrive before the old one leaves.
    func removeAnchor(_ view: NSView, for browser: BrowserModel) {
        if anchors[ObjectIdentifier(browser)]?.view === view { anchors[ObjectIdentifier(browser)] = nil }
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
        confirm(extensionContext, asks: "des autorisations supplémentaires : \(list)") { completionHandler($0 ? permissions : [], nil) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", ")
        confirm(extensionContext, asks: "l'accès à \(hosts)") { completionHandler($0 ? urls : [], nil) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let sites = matchPatterns.map(\.description).sorted().joined(separator: ", ")
        confirm(extensionContext, asks: "l'accès à \(sites)") { completionHandler($0 ? matchPatterns : [], nil) }
    }

    /// A sheet over the frontmost browser window: an app-wide modal loop inside WebKit's callback
    /// would run WebKit's other callbacks re-entrantly.
    private func confirm(_ context: WKWebExtensionContext, asks what: String, _ answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "« \(context.webExtension.displayName ?? "Une extension") » demande \(what)."
        alert.addButton(withTitle: "Autoriser")
        alert.addButton(withTitle: "Refuser")
        guard let window = BrowserWindows.shared.active.window, window.isVisible else {
            answer(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionsRevision &+= 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        let browser = ExtensionBridge.tab(action.associatedTab)?.browser ?? BrowserWindows.shared.active
        guard let popover = action.popupPopover else { return completionHandler(nil) }
        shownPopover = popover
        shownPopupWebView = action.popupWebView
        let anchor = anchors[ObjectIdentifier(browser)]?.view
        // Under the button in the top bar, above it at the bottom of the sidebar.
        let above = anchor?.window.map { anchor!.convert(anchor!.bounds, to: nil).midY < $0.contentLayoutRect.midY } ?? false
        if let webView = action.popupWebView {
            ExtensionPopupSizing.prepare(popover, webView: webView, extensionID: context.uniqueIdentifier, growsUp: above,
                                         screen: anchor?.window?.screen ?? browser.window?.screen)
        }
        if let anchor, anchor.window != nil, !anchor.visibleRect.isEmpty {
            // The anchor isn't flipped: maxY is its top edge.
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: above ? .maxY : .minY)
        } else if let content = browser.window?.contentView {
            // The button isn't shown (tabs hidden at the edge): under the window's top-right corner.
            let corner = NSRect(x: content.bounds.maxX - 40, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
        completionHandler(nil)
    }
}
