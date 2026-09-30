import AppKit
import Observation

/// All browser windows: the main one (`BrowserModel.shared`, a SwiftUI `Window` scene) plus the
/// ⌘N / ⌘⇧N windows, which are AppKit windows hosting the same SwiftUI view so their lifetime is
/// exactly the window's — closing a private window destroys its model and its storage.
@MainActor @Observable
final class BrowserWindows {
    static let shared = BrowserWindows()

    /// The browser of the frontmost browser window: menus and shortcuts act on it.
    private(set) var active: BrowserModel = .shared

    @ObservationIgnored private var controllers: [BrowserWindowController] = []
    @ObservationIgnored private weak var lastNormal: BrowserModel?
    @ObservationIgnored private var sleepTimer: Timer?
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var started = false

    private init() {}

    var all: [BrowserModel] { [.shared] + controllers.map(\.browser) }

    /// Where links opened from other apps go: the frontmost normal window.
    var normalTarget: BrowserModel {
        if !active.isPrivate { return active }
        return lastNormal ?? .shared
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { BrowserWindows.shared.windowBecameKey(note.object as? NSWindow) }
        }
        // The main window is a SwiftUI scene: its model outlives it (see BrowserModel.windowClosed).
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let main = BrowserModel.shared
                if let window = note.object as? NSWindow, window === main.window { main.windowClosed() }
            }
        }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { BrowserWindows.shared.all.forEach { $0.sleepInactiveTabs() } }
        }
        // ⌘= zooms in like ⌘+ (which needs ⇧ on most keyboards), as in Safari.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "=" else { return event }
            let handled = MainActor.assumeIsolated {
                let windows = BrowserWindows.shared
                guard let key = NSApp.keyWindow, windows.all.contains(where: { $0.window === key }) else { return false }
                windows.active.zoom(0.1)
                return true
            }
            return handled ? nil : event
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak pressure] in
            guard let event = pressure?.data else { return }
            MainActor.assumeIsolated { BrowserWindows.shared.memoryPressure(critical: event.contains(.critical)) }
        }
        pressure.resume()
        memoryPressureSource = pressure
    }

    /// macOS runs low on memory: idle tabs go to sleep without waiting for the usual delay
    /// (five minutes of inactivity, none when it's critical), before WebKit has to kill pages.
    func memoryPressure(critical: Bool) {
        let idle: TimeInterval = critical ? 0 : 5 * 60
        NSLog("[Void] mémoire %@ : mise en veille des onglets inactifs depuis %.0f s", critical ? "critique" : "basse", idle)
        all.forEach { $0.sleepInactiveTabs(idleFor: idle) }
    }

    private func windowBecameKey(_ window: NSWindow?) {
        guard let window, let model = all.first(where: { $0.window === window }) else { return }
        if active !== model { active = model }
        ExtensionEvents.windowFocused(model)
        if !model.isPrivate { lastNormal = model }
    }

    // MARK: - Opening windows

    /// ⌘N. Reopens the main window if it was closed, otherwise opens another normal window
    /// showing the same spaces (same storage, so the same logins).
    @discardableResult
    func openNormalWindow() -> BrowserModel {
        let main = BrowserModel.shared
        if main.window?.isVisible != true, let open = main.openWindowAction {
            open(WindowID.main)
            main.window?.makeKeyAndOrderFront(nil)
            return main
        }
        let model = BrowserModel(kind: .secondary, mirroring: normalTarget)
        show(model)
        return model
    }

    /// ⌘⇧N. Every tab of the window is private and shares one in-memory store.
    @discardableResult
    func openPrivateWindow(url: URL? = nil) -> BrowserModel {
        let model = BrowserModel(kind: .privateWindow)
        show(model)
        if let url { model.openTab(url: url) }
        return model
    }

    private func show(_ model: BrowserModel) {
        let reference = NSApp.keyWindow.flatMap { key in all.contains { $0.window === key } ? key : nil } ?? active.window
        let controller = BrowserWindowController(browser: model, cascadingFrom: reference)
        controllers.append(controller)
        ExtensionEvents.windowOpened(model)
        controller.present()
        active = model
        if !model.isPrivate { lastNormal = model }
    }

    func windowWillClose(_ controller: BrowserWindowController) {
        let model = controller.browser
        ExtensionEvents.windowClosing(model)
        model.tearDown()
        controllers.removeAll { $0 === controller }
        if active === model {
            let front = NSApp.orderedWindows.lazy.compactMap { w in self.all.first { $0.window === w } }.first
            active = front ?? .shared
        }
    }
}
