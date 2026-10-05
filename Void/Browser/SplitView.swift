import Foundation

/// Side by side: two tabs of a space shown together, each in one half of the page area. The
/// selected tab is one of them (the focused side: address field, shortcuts, find); clicking into
/// the other side selects it. Selecting a tab outside the pair hides the pair, which comes back
/// when one of its tabs is selected again. Closing either tab ends it.
struct SplitPair: Equatable {
    var left: UUID
    var right: UUID

    func contains(_ id: UUID) -> Bool { left == id || right == id }
    func other(than id: UUID) -> UUID? { left == id ? right : (right == id ? left : nil) }
}

extension BrowserModel {
    /// The two tabs on screen side by side, or nil.
    var shownSplit: (left: Tab, right: Tab)? {
        let space = currentSpace
        guard let pair = space.split, let selected = selectedTab, pair.contains(selected.id),
              let left = space.allTabs.first(where: { $0.id == pair.left }),
              let right = space.allTabs.first(where: { $0.id == pair.right }) else { return nil }
        return (left, right)
    }

    /// The tab shown next to the selected one.
    var splitPartner: Tab? {
        guard let split = shownSplit else { return nil }
        return split.left === selectedTab ? split.right : split.left
    }

    /// Tabs whose page is on screen: the selected one, and its partner side by side.
    var visibleTabs: [Tab] {
        if let split = shownSplit { return [split.left, split.right] }
        return selectedTab.map { [$0] } ?? []
    }

    /// Shows `tab` next to the selected tab (on the right, or in place of the current partner).
    func showSideBySide(_ tab: Tab) {
        guard let selected = selectedTab, tab !== selected, !tab.isClosed,
              let space = selected.space, tab.space === space else { return }
        let before = visibleTabs
        if var pair = space.split, pair.contains(selected.id) {
            if pair.left == selected.id { pair.right = tab.id } else { pair.left = tab.id }
            space.split = pair
        } else {
            space.split = SplitPair(left: selected.id, right: tab.id)
            space.splitRatio = 0.5
        }
        tab.lastAccess = Date()
        tab.ensureWebView()
        PiPController.shared.visibleTabsChanged(from: before, to: visibleTabs)
    }

    /// ⌥⌘S: side by side with the tab used last, or back to a single page.
    func toggleSideBySide() {
        if shownSplit != nil { endSideBySide(); return }
        guard let selected = selectedTab else { return }
        let candidates = currentSpace.allTabs.filter { $0 !== selected && !$0.isClosed }
        guard let partner = candidates.max(by: { $0.lastAccess < $1.lastAccess }) else {
            showToast("rectangle.split.2x1", "Ouvrez un autre onglet pour l'afficher côte à côte")
            return
        }
        showSideBySide(partner)
    }

    /// Back to a single page: the selected tab stays, its partner goes back to the list.
    func endSideBySide() {
        guard shownSplit != nil else { return }
        let before = visibleTabs
        currentSpace.split = nil
        PiPController.shared.visibleTabsChanged(from: before, to: visibleTabs)
    }

    /// Ends the pair `tab` belongs to (shown or not).
    func endSideBySide(of tab: Tab) {
        guard let space = tab.space, space.split?.contains(tab.id) == true else { return }
        if space === currentSpace, shownSplit != nil { endSideBySide() } else { space.split = nil }
    }

    func swapSides() {
        guard shownSplit != nil, let pair = currentSpace.split else { return }
        currentSpace.split = SplitPair(left: pair.right, right: pair.left)
        currentSpace.splitRatio = 1 - currentSpace.splitRatio
    }

    /// Focus goes to the other side.
    func focusOtherSide() {
        if let partner = splitPartner { select(partner) }
    }

    /// A link opened from `tab`'s page next to it (the context menu): it takes the other side.
    func openSideBySide(_ url: URL, beside tab: Tab) {
        let opened = openTab(url: url, background: true, after: tab)
        if selectedTab !== tab { select(tab) }
        showSideBySide(opened)
    }

    /// `tab` is going (closed, put to sleep, moved): its pair ends. Returns the partner.
    @discardableResult
    func leaveSplit(_ tab: Tab) -> Tab? {
        guard let space = tab.space, let pair = space.split, let otherID = pair.other(than: tab.id) else { return nil }
        space.split = nil
        return space.allTabs.first { $0.id == otherID && !$0.isClosed }
    }
}
