import AppKit
import WebKit
import Observation

struct InstalledExtension: Codable, Identifiable, Hashable {
    var id: String          // stable uniqueIdentifier → keeps the extension's storage across launches
    var path: String        // unpacked folder or .zip
}

/// Web extensions through WKWebExtension (macOS 15.4+), optional (Settings → Extensions).
/// Supported: content scripts, CSS, declarativeNetRequest, background scripts, storage,
/// toolbar action + popup. Not bridged: chrome.tabs / chrome.windows (Void doesn't expose
/// its tabs to extensions yet), native messaging.
@available(macOS 15.4, *)
@MainActor @Observable
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionManager()

    @ObservationIgnored let controller = WKWebExtensionController(configuration: .default())
    private(set) var contexts: [WKWebExtensionContext] = []
    var lastError: String?
    @ObservationIgnored private var popover: NSPopover?
    @ObservationIgnored private let listURL = StateStore.directory.appendingPathComponent("extensions.json")

    private override init() {
        super.init()
        controller.delegate = self
    }

    private var installed: [InstalledExtension] {
        get { (try? JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: listURL))) ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: listURL, options: .atomic) } }
    }

    func loadInstalled() {
        for item in installed {
            Task { try? await load(URL(fileURLWithPath: item.path), identifier: item.id) }
        }
    }

    func install(from url: URL) async {
        let id = UUID().uuidString
        do {
            try await load(url, identifier: id)
            installed.append(InstalledExtension(id: id, path: url.path))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uninstall(_ context: WKWebExtensionContext) {
        try? controller.unload(context)
        contexts.removeAll { $0 === context }
        installed.removeAll { $0.id == context.uniqueIdentifier }
    }

    private func load(_ url: URL, identifier: String) async throws {
        let ext = try await WKWebExtension(resourceBaseURL: url)
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = identifier
        context.isInspectable = true
        // Private windows: off unless allowed in Settings → Extensions.
        context.hasAccessToPrivateData = AppSettings.shared.extensionsInPrivate
        // Installing = consenting to what the manifest asks for.
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
        contexts.append(context)
    }

    func applyPrivateAccess() {
        for context in contexts { context.hasAccessToPrivateData = AppSettings.shared.extensionsInPrivate }
    }

    /// Toolbar click on an extension.
    func performAction(_ context: WKWebExtensionContext) {
        context.performAction(for: nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView = action.popupWebView, let window = BrowserWindows.shared.active.window, let content = window.contentView else {
            completionHandler(nil)
            return
        }
        let vc = NSViewController()
        webView.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        vc.view = webView
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 480)
        let anchor = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 40, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: content, preferredEdge: .minY)
        self.popover = popover
        completionHandler(nil)
    }
}
