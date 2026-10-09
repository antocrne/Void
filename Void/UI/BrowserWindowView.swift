import SwiftUI
import AppKit

/// Root of a browser window: sidebar or top-bar layout around the page.
struct BrowserWindowView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Tabs kept hidden (⌘S) and currently revealed by the pointer at the left edge.
    @State private var revealed = false

    var body: some View {
        ZStack {
            ChromeBackground(isPrivate: browser.isPrivate)
            Group {
                switch settings.tabLayout {
                case .sidebar: sidebarLayout
                case .top: topLayout
                }
            }
            if let request = browser.commandBar {
                CommandBarOverlay(request: request, leadingInset: dockedSidebarWidth)
                    .transition(.opacity)
                    .zIndex(10)
            }
            if browser.kind == .main, let step = browser.onboardingStep {
                OnboardingView(step: step)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 640, minHeight: 420)
        .tint(Theme.accent)
        .animation(Theme.quick, value: browser.commandBar)
        .animation(Theme.spring, value: browser.onboardingStep == nil)
        .background(WindowAccessor { window in configure(window) })
        .background(WindowButtonsVisibility(hidden: tabsKeptHidden && !revealed))
        // On the centre line of the top bar (44 pt) or of the sidebar's first row (4 + 30 pt).
        .background(TrafficLightsAlignment(centerY: settings.tabLayout == .top ? 22 : 19))
        .onChange(of: tabsKeptHidden) { revealed = false }
        .onChange(of: settings.chromeLook) { if !browser.isPrivate { browser.window?.backgroundColor = Theme.chromeNS } }
        // Once macOS's transition is over, without animation: changing the bars during it (or
        // animating them) makes SwiftUI resize the window inside AppKit's layout pass, which
        // AppKit stops by raising an exception — Void quit on leaving full screen.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if note.object as? NSWindow === browser.window { browser.isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if note.object as? NSWindow === browser.window { browser.isFullScreen = false }
        }
        .onAppear {
            browser.openWindowAction = { openWindow(id: $0) }
            browser.openSettingsAction = { openSettings() }
        }
    }

    /// ⌘S / Settings → Onglets: the page fills the window, the sidebar appears at the left edge.
    private var tabsKeptHidden: Bool { settings.tabLayout == .sidebar && settings.sidebarAutoHide }

    /// Width taken by the docked sidebar on the left of the page (0 when the page spans the window).
    private var dockedSidebarWidth: CGFloat {
        settings.tabLayout == .sidebar && settings.sidebarVisible && !tabsKeptHidden ? CGFloat(settings.sidebarWidth) : 0
    }

    private var sidebarLayout: some View {
        let hidden = tabsKeptHidden
        let docked = settings.sidebarVisible && !hidden
        let width = CGFloat(settings.sidebarWidth)
        // A private window keeps a slate frame even when the page fills the window.
        let frameInset: CGFloat = hidden ? (browser.isPrivate ? 4 : 0) : 8
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if docked {
                    SidebarView()
                        .frame(width: width)
                        .privateChrome(browser.isPrivate)
                        .overlay(alignment: .trailing) {
                            SidebarResizeHandle(width: settings.sidebarWidth, onResize: resizeSidebar,
                                                onReset: { withAnimation(Theme.spring) { settings.sidebarWidth = AppSettings.defaultSidebarWidth } })
                                .frame(width: 8)
                                .offset(x: 4)
                                .help("Tirer pour élargir · double-clic : largeur par défaut")
                        }
                        .zIndex(1)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    if !settings.sidebarVisible && !hidden {
                        CompactTitleBar()
                            .frame(height: 38)
                            .privateChrome(browser.isPrivate)
                            .transition(.opacity)
                    }
                    if docked && settings.showBookmarksBar {
                        BookmarksBar()
                            .privateChrome(browser.isPrivate)
                            .padding(.bottom, 4)
                            .transition(.opacity)
                    }
                    PageView()
                        .clipShape(RoundedRectangle(cornerRadius: hidden ? 0 : 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: hidden ? 0 : 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: hidden ? 0 : 1))
                        .shadow(color: Theme.shadow.opacity(hidden ? 0 : 0.18), radius: 6, y: 1)
                }
                .padding(.top, docked ? (settings.showBookmarksBar ? 4 : 8) : (hidden ? frameInset : 0))
                .padding([.bottom, .trailing], frameInset)
                .padding(.leading, docked ? 0 : frameInset)
            }
            if hidden {
                EdgeRevealSidebar(revealed: $revealed, width: width)
                if browser.isPrivate && !revealed {
                    PrivateBadge()
                        .padding(.leading, 12)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
    }

    private var topLayout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBarView()
                    .frame(height: 44)
                    .privateChrome(browser.isPrivate)
                if settings.showBookmarksBar {
                    BookmarksBar()
                        .privateChrome(browser.isPrivate)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }
            }
            // Tabs are dragged, the bar's empty places move the window.
            .background(TitleBarDragArea())
            PageView()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
                .padding([.horizontal, .bottom], 6)
        }
    }

    private func resizeSidebar(_ width: Double) {
        let range = AppSettings.sidebarWidthRange
        settings.sidebarWidth = min(range.upperBound, max(range.lowerBound, width))
    }

    private func configure(_ window: NSWindow) {
        browser.window = window
        browser.isFullScreen = window.styleMask.contains(.fullScreen)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.backgroundColor = browser.isPrivate ? Theme.privateChromeNS : Theme.chromeNS
        switch browser.kind {
        case .main:
            window.setFrameAutosaveName("VoidMainWindow")
            ExternalLinks.shared.takeOver()
        case .secondary: window.title = "Void"
        case .privateWindow: window.title = String(localized: "Void — Navigation privée")
        }
    }
}

extension View {
    /// The chrome of a private window is always dark slate, whatever the theme and accent.
    func privateChrome(_ isPrivate: Bool) -> some View {
        transformEnvironment(\.colorScheme) { if isPrivate { $0 = .dark } }
    }
}

/// Tabs kept hidden: a thin zone along the left edge reveals the sidebar above the page;
/// it slides away when the pointer leaves it.
private struct EdgeRevealSidebar: View {
    @Binding var revealed: Bool
    let width: CGFloat
    @Environment(BrowserModel.self) private var browser
    @State private var hideWork: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { if $0 { show() } }
            if revealed {
                SidebarView()
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(ChromeBackground(isPrivate: browser.isPrivate))
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 10, topTrailingRadius: 10, style: .continuous))
                    .shadow(color: Theme.shadow.opacity(0.3), radius: 18, x: 4)
                    .privateChrome(browser.isPrivate)
                    .onHover { inside in inside ? hideWork?.cancel() : scheduleHide() }
                    .transition(.move(edge: .leading))
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        // A new folder's name is typed next to it, in the sidebar: out while it is.
        .onChange(of: browser.renamingFolderID) { _, id in id != nil ? show() : scheduleHide() }
    }

    private func show() {
        hideWork?.cancel()
        guard !revealed else { return }
        withAnimation(Theme.spring) { revealed = true }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            // The downloads popover hangs off the sidebar: stay until it closes.
            if browser.showingDownloads { scheduleHide(); return }
            if browser.renamingFolderID != nil { scheduleHide(); return }
            // Still over the sidebar (e.g. a context menu took the pointer): stay.
            if let window = browser.window, window.mouseLocationOutsideOfEventStream.x <= width + 4,
               window.frame.contains(NSEvent.mouseLocation) {
                scheduleHide()
                return
            }
            withAnimation(Theme.spring) { revealed = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

/// Shown above the page when the sidebar is hidden: room for the traffic lights + essentials.
private struct CompactTitleBar: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        HStack(spacing: 4) {
            // Room for the traffic lights, which full screen hides.
            if !browser.isFullScreen { Color.clear.frame(width: 70) }
            ChromeButton(symbol: "sidebar.left", help: "Afficher la barre latérale (⌃⌘S)") { browser.toggleSidebar() }
            ChromeButton(symbol: "chevron.left", help: "Précédent", disabled: !(browser.selectedTab?.canGoBack ?? false)) { browser.goBack() }
            ChromeButton(symbol: "chevron.right", help: "Suivant", disabled: !(browser.selectedTab?.canGoForward ?? false)) { browser.goForward() }
            if browser.isPrivate { PrivateBadge().padding(.leading, 4) }
            Spacer()
            Text(browser.selectedTab?.displayTitle ?? "Void")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .onTapGesture { browser.showCommandBar(.currentTab) }
            Spacer()
            Color.clear.frame(width: 120)
        }
        .padding(.horizontal, 8)
    }
}
