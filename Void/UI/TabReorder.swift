import AppKit
import SwiftUI

/// Live reordering of tabs by dragging: the sidebar's list of tabs and pinned grid, and the
/// top bar's row. The dragged tab follows the pointer; the others make room as soon as it passes
/// their middle (their cell, in the grid), and the space's order — hence ⌘1…⌘9 and the saved
/// session — changes as it goes. Pinned tabs and ordinary tabs are reordered separately.
@MainActor @Observable
final class TabReorder {
    enum Layout { case vertical, horizontal, grid }

    let layout: Layout
    let spacing: CGFloat
    /// Name of the coordinate space the tabs are measured in (set on their common container).
    let coordinateSpace = "tab-reorder-" + UUID().uuidString

    private(set) var draggedID: UUID?
    /// How far the dragged tab is drawn from the slot it currently occupies in the layout.
    private(set) var offset: CGSize = .zero

    /// Latest layout frames, by tab. Frozen into `snapshot` when a drag starts: while it lasts,
    /// positions are worked out from the order, so they never lag behind a move.
    @ObservationIgnored private var frames: [UUID: CGRect] = [:]
    @ObservationIgnored private var snapshot: [UUID: CGRect] = [:]
    @ObservationIgnored private var cells: [CGRect] = []
    @ObservationIgnored private var startSlot: CGRect = .zero
    @ObservationIgnored private var slot: CGRect = .zero
    @ObservationIgnored private var lineStart: CGFloat = 0

    init(layout: Layout, spacing: CGFloat) {
        self.layout = layout
        self.spacing = spacing
    }

    func record(_ frame: CGRect, for id: UUID) { frames[id] = frame }

    /// `translation` is the pointer's movement since the press.
    func dragChanged(_ tab: Tab, translation: CGSize, browser: BrowserModel) {
        guard let space = tab.space else { return }
        let list = tab.isPinned ? space.pinned : space.tabs
        if draggedID == nil {
            guard let frame = frames[tab.id] else { return }
            snapshot = frames
            cells = list.map { frames[$0.id] ?? .zero }
            startSlot = frame
            slot = frame
            draggedID = tab.id
            // Worked back from the dragged tab: the first rows of a lazy list may never have been measured.
            let before = list.prefix { $0 !== tab }.reduce(CGFloat(0)) { $0 + extent(of: $1.id) + spacing }
            lineStart = (layout == .horizontal ? frame.minX : frame.minY) - before
        }
        guard draggedID == tab.id else { return }

        let center = CGPoint(x: startSlot.midX + translation.width, y: startSlot.midY + translation.height)
        var order = list.map(\.id)
        guard var index = order.firstIndex(of: tab.id) else { return }

        switch layout {
        case .grid:
            // Cells are all the same size: the tab takes the cell under its centre.
            if let target = cells.firstIndex(where: { $0.contains(center) }), target != index, target < order.count {
                browser.moveTab(tab, to: target)
                slot = cells[target]
            }
        case .vertical, .horizontal:
            let c = layout == .horizontal ? center.x : center.y
            while true {
                let spans = lineSpans(order)
                if index + 1 < order.count, c > spans[index + 1].mid {
                    order.swapAt(index, index + 1)
                    index += 1
                } else if index > 0, c < spans[index - 1].mid {
                    order.swapAt(index, index - 1)
                    index -= 1
                } else {
                    slot.origin = layout == .horizontal ? CGPoint(x: spans[index].start, y: startSlot.minY)
                                                        : CGPoint(x: startSlot.minX, y: spans[index].start)
                    break
                }
            }
            if order.firstIndex(of: tab.id) != list.firstIndex(where: { $0 === tab }) {
                browser.moveTab(tab, to: index)
            }
        }

        // A row or a column: the tab stays on it, whatever the pointer does across it.
        offset = CGSize(width: layout == .vertical ? 0 : startSlot.minX + translation.width - slot.minX,
                        height: layout == .horizontal ? 0 : startSlot.minY + translation.height - slot.minY)
    }

    func dragEnded() {
        withAnimation(Theme.spring) {
            draggedID = nil
            offset = .zero
        }
        snapshot = [:]
        cells = []
    }

    /// Start and middle of each tab along the list's axis, in `order`.
    private func lineSpans(_ order: [UUID]) -> [(start: CGFloat, mid: CGFloat)] {
        var spans: [(CGFloat, CGFloat)] = []
        var position = lineStart
        for id in order {
            let extent = extent(of: id)
            spans.append((position, position + extent / 2))
            position += extent + spacing
        }
        return spans
    }

    /// Unmeasured tabs (rows of a lazy list scrolled out of view) are taken to be the dragged one's size.
    private func extent(of id: UUID) -> CGFloat {
        let frame = snapshot[id] ?? startSlot
        return layout == .horizontal ? frame.width : frame.height
    }
}

extension View {
    /// Makes a tab draggable within its list. The list's container needs
    /// `.coordinateSpace(.named(reorder.coordinateSpace))`.
    func tabReorderable(_ tab: Tab, with reorder: TabReorder) -> some View {
        modifier(TabReorderable(tab: tab, reorder: reorder))
    }
}

private struct TabReorderable: ViewModifier {
    let tab: Tab
    let reorder: TabReorder
    @Environment(BrowserModel.self) private var browser

    func body(content: Content) -> some View {
        let dragged = reorder.draggedID == tab.id
        content
            .shadow(color: Theme.shadow.opacity(dragged ? 0.22 : 0), radius: 8, y: 3)
            .offset(dragged ? reorder.offset : .zero)
            // The move changes the dragged tab's slot and its offset by the same amount: animating
            // only the slot would make it lag behind the pointer.
            .transaction { if dragged { $0.animation = nil } }
            .zIndex(dragged ? 1 : 0)
            .background(WindowDragBlocker())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(reorder.coordinateSpace)) } action: {
                reorder.record($0, for: tab.id)
            }
            .onHover { TabDragWindowLock.pointer(isOver: tab.id, $0) }
            // A tab closed with its own cross goes while the pointer is still on it.
            .onDisappear { TabDragWindowLock.pointer(isOver: tab.id, false) }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { reorder.dragChanged(tab, translation: $0.translation, browser: browser) }
                    .onEnded { _ in reorder.dragEnded() }
            )
    }
}

/// Under a tab, a view that says it doesn't move the window. In the top layout the tabs are in
/// the title bar, whose drag regions macOS works out ahead of time from these views (the window
/// server can start moving the window before the app sees the press): the lock below would come
/// too late there. It takes no clicks: the tab's own gestures get them.
private struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> BlockerView { BlockerView() }
    func updateNSView(_ view: BlockerView, context: Context) {}

    final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The window is movable by its background, and SwiftUI's hosting view says the window may be
/// moved from anywhere in it: a tab pressed in the sidebar would take the window with it. So a
/// press that starts on a tab makes its window unmovable until the button is released. The flag
/// is set by a local event monitor, before the window sees the press, which is when AppKit decides.
@MainActor
enum TabDragWindowLock {
    private static var hovered: Set<UUID> = []
    private static weak var locked: NSWindow?
    private static var observers: [Any] = []

    static func pointer(isOver id: UUID, _ inside: Bool) {
        installIfNeeded()
        if inside { hovered.insert(id) } else { hovered.remove(id) }
    }

    private static func installIfNeeded() {
        guard observers.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown, !hovered.isEmpty, let window = event.window {
                    window.isMovable = false
                    locked = window
                } else if event.type == .leftMouseUp {
                    unlock()
                }
            }
            return event
        }) { observers.append(monitor) }
        // A ⌃-click opens the context menu, which keeps the release for itself.
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { unlock() }
        })
    }

    private static func unlock() {
        locked?.isMovable = true
        locked = nil
    }
}
