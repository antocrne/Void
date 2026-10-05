import AppKit
import SwiftUI
import WebKit

/// The extensions, in the chrome: one puzzle button, always there, whose menu lists them (with
/// their badge); choosing one runs its action, and its popup hangs from the button. Without
/// extensions, the menu leads to the Chrome Web Store. Pinned extensions also get their own
/// button, just before it, and their popup hangs from that one.
struct ExtensionsButton: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if #available(macOS 15.4, *), !browser.isPrivate || settings.extensionsInPrivate {
            ExtensionsMenu()
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionsMenu: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false

    var body: some View {
        let manager = ExtensionManager.shared
        let _ = manager.actionsRevision   // redrawn when a badge or an icon changes
        let items = manager.contexts.map { context in (context: context, action: manager.action(context, in: browser)) }
        let pinned = settings.extensionsEnabled ? items.filter { manager.isPinned($0.context) } : []
        // Pinned buttons show their own badge.
        let hasBadge = items.contains { !($0.action?.badgeText.isEmpty ?? true) && !manager.isPinned($0.context) }
        HStack(spacing: 2) {
            ForEach(pinned, id: \.context.uniqueIdentifier) { item in
                PinnedExtensionButton(context: item.context, action: item.action)
            }
            menu(items, hasBadge: hasBadge)
        }
    }

    private func menu(_ items: [(context: WKWebExtensionContext, action: WKWebExtension.Action?)], hasBadge: Bool) -> some View {
        let manager = ExtensionManager.shared
        return Menu {
            if !settings.extensionsEnabled {
                Button("Activer les extensions") { settings.extensionsEnabled = true }
                Divider()
            } else if items.isEmpty {
                Text("Aucune extension")
            }
            ForEach(items, id: \.context.uniqueIdentifier) { item in
                Button { manager.performAction(item.context, in: browser) } label: {
                    let name = item.action?.label.nonEmpty ?? item.context.webExtension.displayName ?? "Extension"
                    let badge = item.action?.badgeText.nonEmpty.map { "  (\($0))" } ?? ""
                    if let icon = item.action?.icon(for: CGSize(width: 16, height: 16)) ?? item.context.webExtension.icon(for: CGSize(width: 16, height: 16)) {
                        Label { Text(name + badge) } icon: { Image(nsImage: icon.voidResized(to: 16)) }
                    } else {
                        Text(name + badge)
                    }
                }
                .disabled(item.action?.isEnabled == false)
            }
            if settings.extensionsEnabled, !items.isEmpty {
                Divider()
                Menu("Épingler à la barre") {
                    ForEach(items, id: \.context.uniqueIdentifier) { item in
                        Toggle(item.context.webExtension.displayName ?? "Extension", isOn: Binding(
                            get: { manager.isPinned(item.context) },
                            set: { manager.setPinned($0, item.context) }))
                    }
                }
            }
            Divider()
            Button("Chrome Web Store") { manager.openWebStore(in: browser) }
            Button("Gérer les extensions…") {
                UserDefaults.standard.set("extensions", forKey: "settingsPanel")
                browser.openSettingsAction?()
            }
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.secondaryText)
        .fixedSize()
        .frame(width: 26, height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.hover : .clear))
        .overlay(alignment: .topTrailing) {
            if hasBadge {
                Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: -3, y: 3).allowsHitTesting(false)
            }
        }
        .background(ExtensionPopupAnchor(browser: browser))
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help("Extensions")
    }
}

/// A pinned extension in the chrome: its icon and badge; a click runs its action (as its line in
/// 🧩's menu does), and its popup hangs from it.
@available(macOS 15.4, *)
private struct PinnedExtensionButton: View {
    @Environment(BrowserModel.self) private var browser
    let context: WKWebExtensionContext
    let action: WKWebExtension.Action?
    @State private var hovering = false

    var body: some View {
        let manager = ExtensionManager.shared
        let name = action?.label.nonEmpty ?? context.webExtension.displayName ?? "Extension"
        let disabled = action?.isEnabled == false
        Button { manager.performAction(context, in: browser) } label: {
            Group {
                if let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16)) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "puzzlepiece").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering && !disabled ? Theme.hover : .clear))
            .overlay(alignment: .bottomTrailing) {
                if let badge = action?.badgeText.nonEmpty {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 2.5)
                        .frame(minWidth: 11, minHeight: 11)
                        .background(Capsule().fill(Theme.accent))
                        .fixedSize()
                        .offset(x: 1, y: 0)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .background(ExtensionPopupAnchor(browser: browser, extensionID: context.uniqueIdentifier))
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help(name)
        .contextMenu {
            Button("Désépingler") { manager.setPinned(false, context) }
            if context.optionsPageURL != nil {
                Button("Options") { manager.openOptions(context) }
            }
            Divider()
            Button("Gérer les extensions…") {
                UserDefaults.standard.set("extensions", forKey: "settingsPanel")
                browser.openSettingsAction?()
            }
        }
    }
}

/// Registers the button's AppKit view: extension popups are shown from it (🧩's: extensionID nil).
@available(macOS 15.4, *)
private struct ExtensionPopupAnchor: NSViewRepresentable {
    let browser: BrowserModel
    var extensionID: String? = nil

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.browser = browser
        view.extensionID = extensionID
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.browser = browser
        view.extensionID = extensionID
    }

    final class AnchorView: NSView {
        weak var browser: BrowserModel?
        var extensionID: String?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated {
                guard let browser else { return }
                if window == nil {
                    ExtensionManager.shared.removeAnchor(self, for: browser, extension: extensionID)
                } else {
                    ExtensionManager.shared.setAnchor(self, for: browser, extension: extensionID)
                }
            }
        }
    }
}

/// On an extension's page of the Chrome Web Store, in the address field: the same as the page's
/// "Ajouter à Void" button (see WebStoreBridge), in case the store changes its page.
struct WebStoreInstallButton: View {
    let tab: Tab

    var body: some View {
        if #available(macOS 15.4, *), let id = ChromeExtensions.webStoreExtensionID(on: tab.url) {
            let manager = ExtensionManager.shared
            let installed = manager.isInstalled(chromeID: id)
            ChromeButton(symbol: installed ? "puzzlepiece.extension.fill" : "puzzlepiece.extension",
                         help: installed ? "Retirer cette extension de Void" : "Ajouter cette extension à Void",
                         active: true, disabled: manager.installing != nil, size: 12) {
                WebStoreBridge.handle(installed ? "remove" : "add", tab: tab)
            }
        }
    }
}

/// The Chrome Web Store's pages and Void: webstore.js puts an "Ajouter à Void" button in place of
/// the store's own, and asks here. Only for the store's main frame, and only for the extension
/// of the page actually shown (never an ID sent by the page).
@available(macOS 15.4, *)
@MainActor
enum WebStoreBridge {
    static func handle(_ action: String?, tab: Tab) {
        guard let webView = tab.webView, webView.url?.host() == "chromewebstore.google.com",
              let id = ChromeExtensions.webStoreExtensionID(on: webView.url) else { return }
        let manager = ExtensionManager.shared
        switch action {
        case "add":
            guard manager.installing == nil else { return }
            show("adding", in: webView)
            Task {
                await manager.installFromWebStore(id)
                if let error = manager.lastError { tab.browser?.showToast("exclamationmark.triangle", error) }
                show(state(of: id), in: webView)
            }
        case "remove":
            if let context = manager.context(chromeID: id) {
                let alert = NSAlert()
                alert.messageText = "Retirer « \(context.webExtension.displayName ?? "cette extension") » de Void ?"
                alert.informativeText = "Ses réglages et ses données sont supprimés."
                alert.addButton(withTitle: "Retirer")
                alert.addButton(withTitle: "Annuler")
                if alert.runModal() == .alertFirstButtonReturn { manager.uninstall(context) }
            }
            show(state(of: id), in: webView)
        default:
            show(state(of: id), in: webView)
        }
    }

    private static func state(of id: String) -> String {
        ExtensionManager.shared.isInstalled(chromeID: id) ? "remove" : "add"
    }

    private static func show(_ state: String, in webView: WKWebView) {
        Task { _ = await webView.voidCall("if (window.__voidStore) window.__voidStore.set(state);", arguments: ["state": state]) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension NSImage {
    /// A copy drawn at `side` points (menus show images at their own size).
    func voidResized(to side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            self.draw(in: rect)
            return true
        }
    }
}
