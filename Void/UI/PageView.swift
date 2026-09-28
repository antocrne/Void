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

            if tab == nil {
                NewTabPage()
                    .transition(.opacity)
            }

            if let tab, tab.isInFloatingPlayer {
                FloatingPlaceholder()
            }

            if let tab, let error = tab.loadError {
                ErrorOverlay(message: error, url: tab.url) { browser.reload() }
            }

            if let tab, let article = tab.reader {
                ReaderView(article: article) { withAnimation(Theme.spring) { tab.reader = nil } }
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }

            if let tab, tab.isLoading {
                ProgressLine(progress: tab.progress)
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
        .onChange(of: browser.selectedTab?.id, initial: true) {
            browser.selectedTab?.ensureWebView()
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
