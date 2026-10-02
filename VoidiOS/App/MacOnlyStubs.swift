import Foundation

// What the model shared with the Mac app calls and that only exists there. On iOS these do
// nothing, so the shared files stay free of platform checks at every call.

/// Extensions (WKWebExtension, Chrome Web Store) are the Mac app's.
@MainActor
enum ExtensionEvents {
    struct Change: OptionSet {
        let rawValue: Int
        static let url = Change(rawValue: 1 << 0)
        static let title = Change(rawValue: 1 << 1)
        static let loading = Change(rawValue: 1 << 2)
        static let pinned = Change(rawValue: 1 << 3)
        static let audio = Change(rawValue: 1 << 4)
        static let readerMode = Change(rawValue: 1 << 5)
    }

    static func tabOpened(_ tab: Tab) {}
    static func tabClosed(_ tab: Tab, windowClosing: Bool = false) {}
    static func tabActivated(_ tab: Tab, previous: Tab?) {}
    static func tabMoved(_ tab: Tab, from index: Int) {}
    static func tabChanged(_ tab: Tab, _ change: Change) {}
}

extension BrowserModel {
    var extensionTabs: [Tab] { spaces.flatMap(\.allTabs) }
}

/// The Mac's floating video window (plan B of Picture in Picture): iOS has the system's PiP only.
@MainActor
final class FloatingPlayer {
    static let shared = FloatingPlayer()
    func close() {}
}

/// iOS runs one copy of an app: there is never a second Void to pass links to.
enum SingleInstance {
    static let isDuplicate = false
}

#if DEBUG
/// The self-tests drive the Mac app (windows, mouse events).
enum SelfTestRunner {
    static let isRequested = false
}
#endif
