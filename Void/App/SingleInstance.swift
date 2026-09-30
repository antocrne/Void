import AppKit

/// Void runs once. Several copies of the app can be installed (/Applications, Xcode builds…) and
/// macOS may hand a link to a copy other than the one running: that copy then launches too, on
/// the same session and website data, and saves its own session over the other's. Such a
/// duplicate shows nothing, passes its links to the running Void and quits without saving.
@MainActor
enum SingleInstance {
    /// The Void that was already running when this one launched, if any.
    static let existing: NSRunningApplication? = {
        #if DEBUG
        if SelfTestRunner.isRequested { return nil }
        #endif
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let me = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }()

    static var isDuplicate: Bool { existing != nil }

    private static var forwarding = false

    /// Launch of a duplicate: no Dock icon, no window, and it leaves if no link arrives.
    static func startDuplicate() {
        NSApp.setActivationPolicy(.prohibited)
        // Links arrive right after launch; without any (another copy opened from the Finder),
        // the running Void just comes to the front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !forwarding { forward([]) }
        }
    }

    /// Hands `urls` to the running Void, which comes to the front, then quits. `exit` skips
    /// `applicationWillTerminate`: this instance must not save its (empty) session.
    static func forward(_ urls: [URL]) {
        guard let existing, !forwarding else { return }
        forwarding = true
        guard !urls.isEmpty, let app = existing.bundleURL else {
            existing.activate()
            exit(0)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
            if let error { NSLog("[Void] liens non transmis à l'instance ouverte : %@", error.localizedDescription) }
            DispatchQueue.main.async { exit(0) }
        }
    }
}
