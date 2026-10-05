import SwiftUI
import WebKit

/// The page area: web content plus the few overlays Void needs.
struct PageView: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let tab = browser.selectedTab
        ZStack(alignment: .top) {
            // On iPhone the page goes up under the status bar, as in Safari: WebKit keeps its
            // content below it until it is scrolled, and fills that strip with the page's colour.
            Theme.surface
                .ignoresSafeArea(edges: .top)

            WebHost(browser: browser)
                .ignoresSafeArea(edges: .top)

            if tab == nil {
                NewTabPage()
                    .transition(.opacity)
            }

            if let tab, let error = tab.loadError {
                ErrorOverlay(message: error, url: tab.url) { browser.reload() }
            }

            if let tab, let article = tab.reader {
                ReaderView(article: article) { withAnimation(Theme.spring) { tab.reader = nil } }
                    .background(Theme.surface)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }

            if let tab, tab.isLoading {
                ProgressLine(progress: tab.progress)
            }

            if let prompt = browser.passwordPrompt {
                PasswordPromptBar(prompt: prompt)
                    .padding(10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let toast = browser.toast {
                ToastView(toast: toast)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
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
                .frame(width: geo.size.width * max(0.08, progress), height: 2.5)
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

/// Empty state of a space.
struct NewTabPage: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        VStack(spacing: 24) {
            if browser.isPrivate {
                Image(systemName: "eye.slash.circle")
                    .font(.system(size: 58, weight: .ultraLight))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                VoidLogo(size: 64)
            }
            VStack(spacing: 8) {
                Text(browser.isPrivate ? "Navigation privée" : "Rien ici. C'est voulu.")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                if browser.isPrivate {
                    Text("Ni historique, ni cookies, ni session : tout disparaît à la fermeture de la navigation privée.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            Button { browser.showCommandBar(.newTab) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(Tab.addressPlaceholder)
                }
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: 340)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.hover))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface.ignoresSafeArea(edges: .top))
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(toast.message).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.primaryText).lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Capsule().fill(.ultraThickMaterial))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .shadow(color: Theme.shadow.opacity(0.25), radius: 14, y: 6)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
    }
}

struct PasswordPromptBar: View {
    let prompt: PasswordSavePrompt
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(Theme.accent)
                Text("Enregistrer le mot de passe ?").font(.system(size: 16, weight: .semibold))
            }
            Text("\(prompt.username.isEmpty ? "Compte" : prompt.username) · \(prompt.host)")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
            Text("Stocké dans le trousseau de l'appareil, affiché uniquement après Face ID, Touch ID ou votre code.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Jamais pour ce site") { PasswordManager.shared.neverForHost(prompt, in: browser) }
                Spacer()
                Button("Plus tard") { browser.passwordPrompt = nil }
                Button("Enregistrer") { PasswordManager.shared.save(prompt, in: browser) }
                    .voidPrimaryButton()
            }
            .font(.system(size: 14))
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
        .shadow(color: Theme.shadow.opacity(0.25), radius: 16, y: 6)
    }
}

struct ErrorOverlay: View {
    let message: String
    let url: URL?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.secondaryText)
            Text("Impossible d'ouvrir la page").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.primaryText)
            Text(message).font(.system(size: 14.5)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            if let host = url?.host() {
                Text(host).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.secondaryText)
            }
            Button("Réessayer", action: retry)
                .voidPrimaryButton()
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

/// Favicon, or the first letter of the site on a tinted tile (Réglages → Les onglets affichent).
struct FaviconView: View {
    let tab: Tab
    var size: CGFloat = 20
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if settings.tabIconStyle == .favicons, let image = tab.favicon {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Theme.accentSoft)
                    .overlay(
                        Text(letter)
                            .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                    )
            }
        }
        .frame(width: size, height: size)
    }

    private var letter: String {
        let source = tab.url?.host()?.voidNormalizedHost ?? tab.displayTitle
        return source.first.map { String($0).uppercased() } ?? "•"
    }
}

extension View {
    /// The chrome of private browsing is always dark slate, whatever the theme and accent.
    func privateChrome(_ isPrivate: Bool) -> some View {
        transformEnvironment(\.colorScheme) { if isPrivate { $0 = .dark } }
    }
}
