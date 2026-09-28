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
