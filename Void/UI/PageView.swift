import SwiftUI
import WebKit

/// The page area: web content plus the few overlays Void needs.
struct PageView: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let tab = browser.selectedTab
        ZStack(alignment: .top) {
            Theme.surface

            WebHost(browser: browser)

            if let split = browser.shownSplit {
                SplitSides(left: split.left, right: split.right)
            } else if let tab {
                PageOverlays(tab: tab)
            } else {
                NewTabPage()
                    .transition(.opacity)
            }

            VStack(alignment: .trailing, spacing: 8) {
                if browser.findBarVisible {
                    FindBar()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let prompt = browser.passwordPrompt {
                    PasswordPromptBar(prompt: prompt)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(12)

            if let toast = browser.toast {
                ToastView(toast: toast)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(Theme.spring, value: browser.passwordPrompt?.id)
        .onChange(of: [browser.selectedTab?.id, browser.splitPartner?.id], initial: true) {
            browser.selectedTab?.ensureWebView()
            browser.splitPartner?.ensureWebView()
        }
    }
}

/// What Void draws over one tab's page (the whole area, or one side of a split).
private struct PageOverlays: View {
    let tab: Tab
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        ZStack(alignment: .top) {
            if tab.isInFloatingPlayer {
                FloatingPlaceholder(isMeeting: FloatingPlayer.shared.mode == .meeting)
            }

            if let error = tab.loadError {
                ErrorOverlay(message: error, url: tab.url) {
                    if browser.selectedTab !== tab { browser.select(tab) }
                    browser.reload()
                }
            }

            if let article = tab.reader {
                ReaderView(article: article) { withAnimation(Theme.spring) { tab.reader = nil } }
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }

            if tab.isLoading {
                ProgressLine(progress: tab.progress)
            }
        }
    }
}

/// Side by side: each tab's overlays over its side, the divider between them (drag to share the
/// width, double-click for halves), and a ring around the side that has the focus.
private struct SplitSides: View {
    let left: Tab
    let right: Tab
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        GeometryReader { geo in
            let space = browser.currentSpace
            let leftWidth = SplitGeometry.leftWidth(geo.size.width, ratio: space.splitRatio)
            HStack(spacing: 0) {
                side(left).frame(width: leftWidth)
                divider(width: geo.size.width, leftWidth: leftWidth, space: space)
                    .frame(width: SplitGeometry.divider)
                side(right).frame(maxWidth: .infinity)
            }
        }
    }

    private func side(_ tab: Tab) -> some View {
        PageOverlays(tab: tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if browser.selectedTab === tab {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
    }

    private func divider(width: CGFloat, leftWidth: CGFloat, space: Space) -> some View {
        ZStack {
            browser.isPrivate ? Theme.privateChrome : Theme.chrome
            Capsule()
                .fill(Theme.secondaryText.opacity(0.45))
                .frame(width: 3, height: 32)
            SidebarResizeHandle(width: Double(leftWidth),
                                onResize: { space.splitRatio = SplitGeometry.ratio(leftWidth: CGFloat($0), in: width) },
                                onReset: { withAnimation(Theme.spring) { space.splitRatio = 0.5 } })
                .help("Tirer pour partager la largeur · double-clic : moitié-moitié")
        }
        .contextMenu {
            Button("Inverser les côtés") { browser.swapSides() }
            Button("Quitter la vue côte à côte") { browser.endSideBySide() }
        }
    }
}

private struct ProgressLine: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.2), Theme.accent], startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * max(0.08, progress), height: 2)
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
