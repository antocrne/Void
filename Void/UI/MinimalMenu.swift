import SwiftUI
import WebKit

/// Minimalist (Settings → Apparence): the one button left of the chrome's tools. Its panel holds
/// the private window, downloads, history, bookmarks, the extensions and Settings; the downloads
/// popover and the extensions' popups hang from it. A download in progress shows its ring in
/// place of the icon, an extension's badge a dot.
struct MinimalMenuButton: View {
    /// Where the panel opens: under the button in a bar at the top, above it at the bottom of the
    /// sidebar, beside it in the reduced sidebar.
    var arrowEdge: Edge = .bottom
    @Environment(BrowserModel.self) private var browser
    @State private var showingPanel = false
    @State private var hovering = false

    var body: some View {
        @Bindable var browser = browser
        let progress = DownloadManager.shared.progress(for: browser)
        Button { showingPanel.toggle() } label: {
            Group {
                if let progress {
                    DownloadProgressIcon(progress: progress)
                } else {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering || showingPanel || browser.showingDownloads ? Theme.hover : .clear))
            .overlay(alignment: .topTrailing) {
                if extensionBadge {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: -3, y: 3).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Menu")
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .popover(isPresented: $showingPanel, arrowEdge: arrowEdge) {
            MinimalMenuPanel { showingPanel = false }
        }
        // Downloads: this button stands for the downloads button (⌥⌘L opens its popover).
        .background {
            Color.clear
                .popover(isPresented: $browser.showingDownloads, arrowEdge: arrowEdge) { DownloadsPopover(browser: browser) }
                .onAppear { browser.downloadsButtonsShown += 1 }
                .onDisappear {
                    browser.downloadsButtonsShown -= 1
                    if browser.downloadsButtonsShown == 0 { browser.showingDownloads = false }
                }
        }
        .background { ExtensionsAnchor() }
    }

    private var extensionBadge: Bool {
        guard #available(macOS 15.4, *), let manager = ExtensionManager.running, AppSettings.shared.extensionsEnabled else { return false }
        _ = manager.actionsRevision
        return manager.contexts.contains { !(manager.action($0, in: browser)?.badgeText.isEmpty ?? true) }
    }
}

/// Extension popups hang from the menu button while 🧩 isn't shown.
private struct ExtensionsAnchor: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionPopupAnchor(browser: browser)
        }
    }
}

/// The panel: actions as rows, the extensions under them.
private struct MinimalMenuPanel: View {
    let dismiss: () -> Void
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var creatingSpace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if browser.isPrivate {
                row("xmark.circle", "Fermer la fenêtre privée", shortcut: "⌘⇧W") { browser.window?.performClose(nil) }
            } else {
                row("eye.slash", "Nouvelle fenêtre privée", shortcut: "⌘⇧N") { BrowserWindows.shared.openPrivateWindow() }
            }
            row("arrow.down.circle", "Téléchargements", detail: DownloadManager.shared.speedText(for: browser), shortcut: "⌥⌘L", after: 0.2) {
                browser.showingDownloads = true
            }
            if !browser.isPrivate {
                row("clock", "Historique", shortcut: "⌘Y") { browser.showLibrary(.history) }
                row("book", "Favoris") { browser.showLibrary(.bookmarks) }
            }
            if browser.managesSpaces {
                row("folder.badge.plus", "Nouveau dossier", shortcut: "⌃⌘N") { browser.addFolder() }
                Button { creatingSpace = true } label: {
                    MinimalMenuRow(symbol: "square.stack", title: "Nouvel espace…")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $creatingSpace, arrowEdge: .trailing) {
                    NewSpaceForm {
                        creatingSpace = false
                        dismiss()
                    }
                }
            }

            if #available(macOS 15.4, *), !browser.isPrivate || settings.extensionsInPrivate {
                Divider().padding(.vertical, 4)
                MinimalExtensionsSection(dismiss: dismiss)
            }

            Divider().padding(.vertical, 4)
            row("gearshape", "Réglages", shortcut: "⌘,") { browser.openSettingsAction?() }
        }
        .padding(6)
        .frame(width: 264)
    }

    /// `after`: what the row does once the panel is gone (a popover from the same button).
    private func row(_ symbol: String, _ title: LocalizedStringKey, detail: String? = nil, shortcut: String? = nil,
                     after delay: Double = 0, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            } else {
                action()
            }
        } label: {
            MinimalMenuRow(symbol: symbol, title: title, detail: detail, shortcut: shortcut)
        }
        .buttonStyle(.plain)
    }
}

/// A row of the panel: symbol, title, a detail and the shortcut on the right.
private struct MinimalMenuRow<Icon: View>: View {
    let icon: Icon
    let title: Text
    var detail: String?
    var shortcut: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 18)
            title
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let detail {
                Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            if let shortcut {
                Text(verbatim: shortcut).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension MinimalMenuRow where Icon == AnyView {
    init(symbol: String, title: LocalizedStringKey, detail: String? = nil, shortcut: String? = nil) {
        self.init(icon: AnyView(Image(systemName: symbol).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondaryText)),
                  title: Text(title), detail: detail, shortcut: shortcut)
    }

    init(image: NSImage, verbatim title: String, detail: String? = nil) {
        self.init(icon: AnyView(Image(nsImage: image.voidResized(to: 16))), title: Text(verbatim: title), detail: detail)
    }
}

/// The extensions, as 🧩's menu lists them: a click runs one (its popup hangs from the menu button).
@available(macOS 15.4, *)
private struct MinimalExtensionsSection: View {
    let dismiss: () -> Void
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let manager = ExtensionManager.shared
        let _ = manager.actionsRevision
        Text("Extensions")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
        if !settings.extensionsEnabled {
            Button {
                settings.extensionsEnabled = true
            } label: {
                MinimalMenuRow(symbol: "puzzlepiece.extension", title: "Activer les extensions")
            }
            .buttonStyle(.plain)
        } else {
            ForEach(manager.contexts, id: \.uniqueIdentifier) { context in
                let action = manager.action(context, in: browser)
                let name = action?.label.isEmpty == false ? action!.label : (context.webExtension.displayName ?? "Extension")
                Button {
                    dismiss()
                    // Once the panel is gone: the extension's popup hangs from the same button.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { manager.performAction(context, in: browser) }
                } label: {
                    if let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16)) {
                        MinimalMenuRow(image: icon, verbatim: name, detail: action?.badgeText.isEmpty == false ? action!.badgeText : nil)
                    } else {
                        MinimalMenuRow(icon: AnyView(Image(systemName: "puzzlepiece").foregroundStyle(Theme.secondaryText)), title: Text(verbatim: name))
                    }
                }
                .buttonStyle(.plain)
                .disabled(action?.isEnabled == false)
            }
            Button {
                dismiss()
                manager.openWebStore(in: browser)
            } label: {
                MinimalMenuRow(symbol: "bag", title: "Chrome Web Store")
            }
            .buttonStyle(.plain)
        }
        Button {
            dismiss()
            UserDefaults.standard.set("extensions", forKey: "settingsPanel")
            browser.openSettingsAction?()
        } label: {
            MinimalMenuRow(symbol: "puzzlepiece.extension", title: "Gérer les extensions…")
        }
        .buttonStyle(.plain)
    }
}
