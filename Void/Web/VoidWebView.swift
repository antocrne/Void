import AppKit
import WebKit

/// WKWebView with Void's context menu ("Open Link in New Tab"…).
final class VoidWebView: WKWebView {
    weak var tab: Tab?
    /// Link / image under the last right-click, reported by core.js just before the menu opens.
    var contextLinkURL: URL?
    var contextImageURL: URL?
    /// Text selected in the frame of the last right-click (same report).
    var contextSelection = ""
    /// Set when one of WebKit's "Ouvrir … dans un nouvel onglet" items is chosen: the tab it
    /// creates (createWebViewWith, a moment later) opens behind, the page stays on screen.
    private var contextMenuOpenDate: Date?
    /// Key-downs given to WebKit: one of them coming back is WebKit re-sending an event the
    /// page didn't handle (see keyDown). The page answers late when it is busy (a video
    /// seeking), so several can be waiting at once (keys pressed in a row, a key held down).
    private let sentKeyDowns = NSHashTable<NSEvent>.weakObjects()

    /// A key the page leaves unhandled (an arrow in a video player that doesn't block it, on a
    /// page that can't scroll, or in fullscreen) is re-sent by WebKit up the responder chain,
    /// where nothing takes it and macOS plays the "impossible action" sound. Menu shortcuts
    /// are matched before this point, so the re-sent event is simply dropped; ⌘ combinations
    /// that nothing handles keep the system's answer.
    override func keyDown(with event: NSEvent) {
        if sentKeyDowns.contains(event) {
            sentKeyDowns.remove(event)
            if !event.modifierFlags.contains(.command) {
                #if DEBUG
                droppedKeyDowns += 1
                #endif
                return
            }
        } else {
            sentKeyDowns.add(event)
        }
        super.keyDown(with: event)
    }

    #if DEBUG
    /// Unhandled key-downs dropped instead of beeping (self-test).
    var droppedKeyDowns = 0
    #endif

    /// Side by side: a click into the other side's page gives it the focus (address field, shortcuts).
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { MainActor.assumeIsolated { focusSplitSide() } }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { focusSplitSide() }
        super.mouseDown(with: event)
    }

    @MainActor
    private func focusSplitSide() {
        guard let tab, let browser = tab.browser, browser.selectedTab !== tab, browser.splitPartner === tab else { return }
        DispatchQueue.main.async { if browser.splitPartner === tab { browser.select(tab) } }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        MainActor.assumeIsolated { customize(menu) }
        #if DEBUG
        if let hook = Self.menuTestHook {
            Self.menuTestHook = nil
            hook(menu)
        }
        #endif
    }

    #if DEBUG
    /// Self-test: receives the next context menu as it opens (to pick an item and close it).
    static var menuTestHook: ((NSMenu) -> Void)?
    #endif

    /// A page that swallows the next right-click before core.js sees it must not get this link
    /// offered again.
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        contextLinkURL = nil
        contextImageURL = nil
        contextSelection = ""
    }

    /// True once per context-menu "Ouvrir … dans un nouvel onglet": the new tab stays behind.
    /// A page that never asks for the window leaves the flag, so it expires.
    func consumeContextMenuOpen() -> Bool {
        defer { contextMenuOpenDate = nil }
        guard let date = contextMenuOpenDate else { return false }
        return Date().timeIntervalSince(date) < 2
    }

    @MainActor
    private func customize(_ menu: NSMenu) {
        forwardedActions.removeAll()
        var linkItemIndex: Int?
        for (index, item) in menu.items.enumerated() {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow":
                // WebKit's action calls createWebViewWith → BrowserModel opens a tab.
                item.title = String(localized: "Ouvrir le lien dans un nouvel onglet")
                linkItemIndex = index
                openBehind(item)
            case "WKMenuItemIdentifierOpenImageInNewWindow":
                item.title = String(localized: "Ouvrir l'image dans un nouvel onglet")
                openBehind(item)
            case "WKMenuItemIdentifierOpenFrameInNewWindow":
                item.title = String(localized: "Ouvrir le cadre dans un nouvel onglet")
                openBehind(item)
            case "WKMenuItemIdentifierOpenMediaInNewWindow":
                item.title = String(localized: "Ouvrir la vidéo dans un nouvel onglet")
                openBehind(item)
            default:
                break
            }
        }

        if let linkItemIndex, let link = contextLinkURL {
            let side = NSMenuItem(title: String(localized: "Ouvrir le lien côte à côte"), action: #selector(openLinkSideBySide(_:)), keyEquivalent: "")
            side.representedObject = link
            side.target = self
            menu.insertItem(side, at: linkItemIndex + 1)
            if tab?.isPrivate == false {
                let privateItem = NSMenuItem(title: String(localized: "Ouvrir dans une fenêtre privée"), action: #selector(openLinkPrivately(_:)), keyEquivalent: "")
                privateItem.representedObject = link
                privateItem.target = self
                menu.insertItem(privateItem, at: linkItemIndex + 2)
            }
        } else if linkItemIndex == nil, let link = contextLinkURL {
            // Some menus (e.g. link inside an image) lack WebKit's item: add ours.
            let item = NSMenuItem(title: String(localized: "Ouvrir le lien dans un nouvel onglet"), action: #selector(openLinkInBackground(_:)), keyEquivalent: "")
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
        if tab?.isInCall == true {
            let pip = NSMenuItem(title: String(localized: "Réunion en fenêtre flottante"), action: #selector(togglePiP), keyEquivalent: "")
            pip.target = self
            menu.addItem(pip)
        } else if tab?.hasVideo == true {
            let pip = NSMenuItem(title: "Picture in Picture", action: #selector(togglePiP), keyEquivalent: "")
            pip.target = self
            menu.addItem(pip)
        }
        // Void Notes: the selection when there is one, the page otherwise. Without the app the
        // item stays, disabled (no action), and says why.
        let notes = VoidNotes.shared
        notes.refresh()
        let selection = contextSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        let send = NSMenuItem(title: notes.menuTitle(selection.isEmpty ? "Envoyer la page vers Void Notes" : "Envoyer vers Void Notes"),
                              action: notes.isInstalled ? #selector(sendToNotes(_:)) : nil, keyEquivalent: "")
        send.representedObject = selection
        send.target = self
        send.isEnabled = notes.isInstalled
        if !notes.isInstalled { send.toolTip = VoidNotes.missingHint }
        menu.addItem(send)
        let hide = NSMenuItem(title: String(localized: "Masquer un élément…"), action: #selector(hideElement), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
    }

    /// WebKit's own items keep their action (it carries the opener and the referrer), routed
    /// through forwardOpenBehind so the tab it creates is marked to open behind.
    private func openBehind(_ item: NSMenuItem) {
        guard let action = item.action, action != #selector(forwardOpenBehind(_:)) else { return }
        forwardedActions[ObjectIdentifier(item)] = (item.target, action)
        item.target = self
        item.action = #selector(forwardOpenBehind(_:))
    }

    private var forwardedActions: [ObjectIdentifier: (target: AnyObject?, action: Selector)] = [:]

    @objc private func forwardOpenBehind(_ sender: NSMenuItem) {
        guard let original = forwardedActions[ObjectIdentifier(sender)] else { return }
        forwardedActions.removeAll()
        contextMenuOpenDate = Date()
        NSApp.sendAction(original.action, to: original.target, from: sender)
    }

    @objc private func openLinkInBackground(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated {
            _ = (tab?.browser ?? .shared).openTab(url: url, background: true, after: tab)
        }
    }

    @objc private func openLinkSideBySide(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated {
            guard let tab, let browser = tab.browser else { return }
            browser.openSideBySide(url, beside: tab)
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

    @objc private func sendToNotes(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard let tab else { return }
            let selection = sender.representedObject as? String ?? ""
            if selection.isEmpty { VoidNotes.shared.sendPage(from: tab) } else { VoidNotes.shared.sendSelection(selection, from: tab) }
        }
    }

    @objc private func hideElement() {
        MainActor.assumeIsolated {
            guard let tab else { return }
            ElementHider.shared.startPicking(in: tab)
        }
    }
}
