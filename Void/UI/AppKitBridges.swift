import AppKit
import SwiftUI

/// Gives access to the hosting NSWindow to configure it once.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The top bar is also the window's title bar, where macOS would move the window from anywhere
/// — tabs included, before they can be dragged. While this view is in a window, the window
/// can't be moved by the system; it moves only from the bar's empty places (this view, behind
/// the bar's content), and a double-click there does what the title bar's would.
struct TitleBarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        /// As a title bar: an inactive window is moved by its first click.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            // Back to the sidebar layout: the window is movable by its background again.
            if newWindow == nil { window?.isMovable = true }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isMovable = false
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.zoom(nil)
                }
                return
            }
            // The pointer keeps its place in the window while the window follows it.
            let grab = event.locationInWindow
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
                let pointer = window.convertPoint(toScreen: next.locationInWindow)
                window.setFrameOrigin(NSPoint(x: pointer.x - grab.x, y: pointer.y - grab.y))
            }
        }
    }
}

/// Detects a horizontal two-finger swipe over its area (sidebar / tab bar) to switch spaces.
/// Uses a local event monitor so it works above SwiftUI buttons and lists without stealing
/// vertical scrolling.
struct SpaceSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onSwipe = onSwipe
    }

    final class CatcherView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, event.hasPreciseScrollingDeltas else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }
            switch event.phase {
            case .began:
                accumulated = 0
                fired = false
            case .changed:
                guard !fired, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
                // Finger movement, independent of the "natural scrolling" setting.
                let fingerDelta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
                accumulated += fingerDelta
                if abs(accumulated) > 70 {
                    fired = true
                    // Fingers moving left → next space (content slides left).
                    onSwipe?(accumulated < 0 ? 1 : -1)
                }
            case .ended, .cancelled:
                accumulated = 0
                fired = false
            default:
                break
            }
        }
    }
}

/// The draggable right edge of the sidebar: drag to resize, double-click to restore the default
/// width. AppKit so the drag never moves the window (the window is movable by its background).
struct SidebarResizeHandle: NSViewRepresentable {
    let width: Double
    let onResize: (Double) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.width = width
        view.onResize = onResize
        view.onReset = onReset
    }

    final class HandleView: NSView {
        var width: Double = 0
        var onResize: ((Double) -> Void)?
        var onReset: (() -> Void)?
        private var startX: CGFloat = 0
        private var startWidth: Double = 0

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onReset?()
                return
            }
            startX = event.locationInWindow.x
            startWidth = width
        }

        override func mouseDragged(with event: NSEvent) {
            onResize?(startWidth + Double(event.locationInWindow.x - startX))
        }
    }
}

/// Shows or hides the window's traffic lights (hidden while the tabs are kept hidden and the
/// page fills the window; they come back with the revealed sidebar).
struct WindowButtonsVisibility: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let hidden = hidden
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            // Really hidden (not just transparent): an invisible close button must not be clickable.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = hidden
            }
        }
    }
}

/// Moves the window's traffic lights down so they share a centre line with the chrome's first
/// row of buttons (macOS centres them 16 pt from the top, our rows sit lower). AppKit lays the
/// title bar out again on resize or key changes, so the offset is reapplied whenever a button moves.
struct TrafficLightsAlignment: NSViewRepresentable {
    /// Distance from the window's top edge to the buttons' centre.
    let centerY: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.centerY = centerY
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var centerY: CGFloat = 16
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var applyPending = false

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func attach(to window: NSWindow) {
            if self.window !== window {
                self.window = window
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = buttons(of: window).map { button in
                    button.postsFrameChangedNotifications = true
                    return NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                        self?.scheduleApply()
                    }
                }
            }
            apply()
        }

        /// AppKit puts the buttons back one after the other during its title bar layout: moving
        /// them from inside that pass loses to the next reset (the last one, zoom, stayed up).
        /// Waiting for the pass to end moves all three once it is done.
        private func scheduleApply() {
            guard !applyPending else { return }
            applyPending = true
            DispatchQueue.main.async { [weak self] in
                self?.applyPending = false
                self?.apply()
            }
        }

        private func buttons(of window: NSWindow) -> [NSButton] {
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        }

        private func apply() {
            // Full screen: the buttons live in the menu-bar reveal, leave them where macOS puts them.
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for button in buttons(of: window) {
                guard let titleBar = button.superview else { continue }
                let fromTop = centerY - button.frame.height / 2
                let y = titleBar.isFlipped ? fromTop : titleBar.bounds.height - fromTop - button.frame.height
                // Setting the same origin posts no notification, so this doesn't loop.
                if button.frame.origin.y != y { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
            }
        }
    }
}
