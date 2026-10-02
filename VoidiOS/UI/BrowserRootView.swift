import SwiftUI
import QuickLook

/// Root of the app: the page with Void's few pixels of chrome around it.
///  • iPhone (and narrow iPad windows): the page above a bottom bar; tabs and spaces in a sheet.
///  • iPad: tabs and spaces in a sidebar, as on the Mac, and a thin bar above the page.
struct BrowserRootView: View {
    @State private var windows = BrowserWindows.shared
    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sheet: BrowserSheet?

    private var browser: BrowserModel { windows.active }
    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        @Bindable var windows = windows
        ZStack {
            (browser.isPrivate ? Theme.privateChrome : Theme.chrome)
                .ignoresSafeArea()

            Group {
                if compact { compactLayout } else { regularLayout }
            }
            // The page keeps its size when the keyboard comes up: WebKit scrolls the field into view.
            .ignoresSafeArea(.keyboard)

            if let request = browser.commandBar {
                CommandBarOverlay(request: request)
                    .id(request.id)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .environment(browser)
        .tint(Theme.accent)
        .animation(Theme.quick, value: browser.commandBar)
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .tabs:
                    TabsPanel(inSheet: true) { self.sheet = nil }
                        .background((browser.isPrivate ? Theme.privateChrome : Theme.chrome).ignoresSafeArea())
                        .privateChrome(browser.isPrivate)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                case .library:
                    LibraryView()
                case .settings:
                    SettingsView()
                }
            }
            .environment(browser)
            .environment(settings)
            .tint(Theme.accent)
        }
        .quickLookPreview($windows.previewedFile)
        .onAppear {
            settings.applyAppearance()
            // The shared model asks for these by name (windows on the Mac, sheets here).
            BrowserModel.shared.openWindowAction = { id in if id == WindowID.library { sheet = .library } }
            BrowserModel.shared.openSettingsAction = { sheet = .settings }
        }
        .onChange(of: compact) { if !compact, sheet == .tabs { sheet = nil } }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            PageView()
            BottomBar { sheet = .tabs }
                .privateChrome(browser.isPrivate)
        }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            if settings.sidebarVisible {
                TabsPanel(inSheet: false) {}
                    .frame(width: 300)
                    .privateChrome(browser.isPrivate)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                TopBar()
                    .privateChrome(browser.isPrivate)
                PageView()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
                    .padding(.trailing, 8)
                    .padding(.leading, settings.sidebarVisible ? 0 : 8)
                    .padding(.bottom, 8)
            }
        }
        .animation(Theme.spring, value: settings.sidebarVisible)
    }
}

enum BrowserSheet: String, Identifiable {
    case tabs, library, settings
    var id: String { rawValue }
}
