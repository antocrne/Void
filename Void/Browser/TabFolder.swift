import Foundation
import Observation

/// A folder of tabs kept for later, in its space's sidebar: they sleep there, in order, and one
/// wakes up when clicked. Folded or unfolded at will; always saved with the session (main window).
@MainActor @Observable
final class TabFolder: Identifiable {
    let id: UUID
    var name: String
    var isExpanded: Bool
    var tabs: [Tab] = []

    init(id: UUID = UUID(), name: String, isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
    }

    /// The rows under its header: all its tabs, or — folded — only the one being shown, if any.
    func shownTabs(selectedID: UUID?) -> [Tab] {
        isExpanded ? tabs : tabs.filter { $0.id == selectedID }
    }
}

extension Space {
    /// The folder holding `tab`, if any.
    func folder(of tab: Tab) -> TabFolder? {
        folders.first { $0.tabs.contains { $0 === tab } }
    }

    /// The list `tab` is ordered in: the pinned tabs, its folder's tabs, or the space's tabs.
    func siblings(of tab: Tab) -> [Tab] {
        if tab.isPinned { return pinned }
        return folder(of: tab)?.tabs ?? tabs
    }

    /// Takes `tab` out of whichever list holds it.
    func detach(_ tab: Tab) {
        pinned.removeAll { $0 === tab }
        tabs.removeAll { $0 === tab }
        for folder in folders { folder.tabs.removeAll { $0 === tab } }
    }

    /// The tabs on screen, in their order: ⌘1…⌘9 and ⌃⇥ go through these (a folded folder's
    /// tabs aren't woken up by them).
    var navigableTabs: [Tab] {
        pinned + folders.flatMap { $0.shownTabs(selectedID: selectedTabID) } + tabs
    }
}
