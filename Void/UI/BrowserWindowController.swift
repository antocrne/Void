import AppKit
import SwiftUI

/// Root view of every browser window (main scene and ⌘N / ⌘⇧N windows).
struct BrowserRootView: View {
    let browser: BrowserModel
    var body: some View {
        BrowserWindowView()
            .environment(browser)
            .environment(AppSettings.shared)
    }
}

/// An extra browser window (⌘N, ⌘⇧N). Its model lives exactly as long as the window.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let browser: BrowserModel

    /// `reference`: the window to cascade from (the new window takes its size).
    init(browser: BrowserModel, cascadingFrom reference: NSWindow?) {
        self.browser = browser
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Final frame first, *then* the SwiftUI content: a hosting view laid out at one size and
        // then resized by the window before its first layout would "correct" the window in a loop.
        if let reference, reference.isVisible {
            var frame = reference.frame
            frame.origin.x += 26
            frame.origin.y -= 26
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        let container = NSView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
        let hosting = NSHostingView(rootView: BrowserRootView(browser: browser))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        super.init(window: window)
        window.delegate = self
        browser.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        BrowserWindows.shared.windowWillClose(self)
    }
}
