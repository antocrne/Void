import AppKit
import WebKit

/// WKWebView with Void's context menu ("Open Link in New Tab"…).
final class VoidWebView: WKWebView {
    weak var tab: Tab?
    /// Link / image under the last right-click, reported by core.js just before the menu opens.
    var contextLinkURL: URL?
    var contextImageURL: URL?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        MainActor.assumeIsolated { customize(menu) }
    }

    @MainActor
    private func customize(_ menu: NSMenu) {
        var linkItemIndex: Int?
        for (index, item) in menu.items.enumerated() {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow":
                // WebKit's action calls createWebViewWith → BrowserModel opens a tab.
                item.title = "Ouvrir le lien dans un nouvel onglet"
                linkItemIndex = index
            case "WKMenuItemIdentifierOpenImageInNewWindow":
                item.title = "Ouvrir l'image dans un nouvel onglet"
            case "WKMenuItemIdentifierOpenFrameInNewWindow":
                item.title = "Ouvrir le cadre dans un nouvel onglet"
            case "WKMenuItemIdentifierOpenMediaInNewWindow":
                item.title = "Ouvrir la vidéo dans un nouvel onglet"
            default:
                break
            }
        }

        if let linkItemIndex, let link = contextLinkURL {
            let background = NSMenuItem(title: "Ouvrir dans un onglet en arrière-plan", action: #selector(openLinkInBackground(_:)), keyEquivalent: "")
            background.representedObject = link
            background.target = self
            menu.insertItem(background, at: linkItemIndex + 1)
            if tab?.isPrivate == false {
                let privateItem = NSMenuItem(title: "Ouvrir dans une fenêtre privée", action: #selector(openLinkPrivately(_:)), keyEquivalent: "")
                privateItem.representedObject = link
                privateItem.target = self
                menu.insertItem(privateItem, at: linkItemIndex + 2)
            }
        } else if linkItemIndex == nil, let link = contextLinkURL {
            // Some menus (e.g. link inside an image) lack WebKit's item: add ours.
            let item = NSMenuItem(title: "Ouvrir le lien dans un nouvel onglet", action: #selector(openLinkInForeground(_:)), keyEquivalent: "")
            item.representedObject = link
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        if #available(macOS 15.4, *), let tab, let manager = ExtensionManager.running {
            let items = manager.menuItems(for: tab)
            if !items.isEmpty {
                menu.addItem(.separator())
                items.forEach(menu.addItem)
            }
        }

        menu.addItem(.separator())
        if tab?.hasVideo == true {
            let pip = NSMenuItem(title: "Picture in Picture", action: #selector(togglePiP), keyEquivalent: "")
            pip.target = self
            menu.addItem(pip)
        }
        let hide = NSMenuItem(title: "Masquer un élément…", action: #selector(hideElement), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
    }

    @objc private func openLinkInBackground(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated {
            _ = (tab?.browser ?? .shared).openTab(url: url, background: true, after: tab)
        }
    }

    @objc private func openLinkInForeground(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated {
            _ = (tab?.browser ?? .shared).openTab(url: url, after: tab)
        }
    }

    @objc private func openLinkPrivately(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated { _ = BrowserWindows.shared.openPrivateWindow(url: url) }
    }

    @objc private func togglePiP() {
        MainActor.assumeIsolated {
            guard let tab else { return }
            Task { await PiPController.shared.toggle(tab) }
        }
    }

    @objc private func hideElement() {
        MainActor.assumeIsolated {
            guard let tab else { return }
            ElementHider.shared.startPicking(in: tab)
        }
    }
}
