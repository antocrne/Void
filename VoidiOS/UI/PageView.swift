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

/// The new-tab page (« + »), also the empty state of a space: its field opens what is typed in a
/// new tab, with the suggestions of the address bar under it, as on the Mac.
struct NewTabPage: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var text = ""
    /// Recomputed when the text changes only: it queries the history database.
    @State private var suggestions: [Suggestion] = []
    @FocusState private var focused: Bool
    /// Top of the keyboard on screen (the page goes on under it: BrowserRootView ignores it).
    @State private var keyboardTop: CGFloat = .infinity

    private static let fieldHeight: CGFloat = 50
    private static let rowHeight: CGFloat = 50

    /// The page's own background, or with a tint (Settings → Teinte), the tint as frosted glass.
    @ViewBuilder private var background: some View {
        if browser.isPrivate || settings.chromeTint == .none {
            Theme.surface
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                ChromeFill(look: settings.chromeLook).opacity(Theme.frostedTintOpacity)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            // What the keyboard leaves of the page.
            let visible = max(0, min(frame.height, keyboardTop - frame.minY))
            let listing = !suggestions.isEmpty
            VStack(spacing: 22) {
                if !listing { header.transition(.opacity.combined(with: .scale(scale: 0.96))) }
                VStack(spacing: 8) {
                    fieldRow
                    if listing {
                        list.frame(maxHeight: max(0, visible - Self.fieldHeight - 34))
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, listing ? 12 : 0)
            .frame(maxWidth: 560)
            .frame(width: geo.size.width, height: visible, alignment: listing ? .top : .center)
            .animation(Theme.spring, value: listing)
            .animation(Theme.spring, value: keyboardTop)
        }
        .background(background.ignoresSafeArea(edges: .top).onTapGesture { focused = false })
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardTop = end.minY >= UIScreen.main.bounds.height ? .infinity : end.minY
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardTop = .infinity
        }
        // « + » again, or the address field tapped here: a fresh field, keyboard up.
        .onChange(of: browser.newTabFieldRequest, initial: true) {
            guard browser.newTabFieldRequest != browser.newTabFieldAnswered else { return }
            browser.newTabFieldAnswered = browser.newTabFieldRequest
            text = ""
            DispatchQueue.main.async { focused = true }
        }
    }

    private var header: some View {
        VStack(spacing: 22) {
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
        }
    }

    private var fieldRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: browser.isPrivate ? "eye.slash" : "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(focused ? Theme.accent : Theme.secondaryText)
                // Short: it shares the line with « Annuler » on an iPhone.
                TextField("Recherche ou adresse", text: $text)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.primaryText)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(commit)
                    .onKeyPress(.escape) { cancel(); return .handled }
                    .onChange(of: text) {
                        suggestions = text.isEmpty ? [] : SuggestionEngine.suggestions(for: text, browser: browser)
                    }
                    // Exchange rates that have just arrived: the conversion typed gets its answer.
                    .onChange(of: CurrencyRates.shared.revision) {
                        if !text.isEmpty { suggestions = SuggestionEngine.suggestions(for: text, browser: browser) }
                    }
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 30, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Effacer")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, text.isEmpty ? 14 : 4)
            .frame(height: Self.fieldHeight)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(focused ? Theme.elevated : Theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if focused || browser.tabBeforeNewTabPage != nil {
                Button("Annuler", action: cancel)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.quick, value: focused)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(suggestions) { suggestion in
                    SuggestionRow(suggestion: suggestion) { text = $0 }
                        .frame(height: Self.rowHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { run(suggestion) }
                }
            }
            .padding(6)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// ↩: the first suggestion — the address typed when it is one, the search otherwise.
    private func commit() {
        if let first = SuggestionEngine.suggestions(for: text, browser: browser).first {
            run(first)
        } else if !text.isEmpty {
            browser.navigate(text, mode: .newTab)
            text = ""
        }
    }

    private func run(_ suggestion: Suggestion) {
        text = ""
        focused = false
        suggestion.perform(in: browser, mode: .newTab)
    }

    /// Back to the tab the page was opened over; with none, just puts the keyboard away.
    private func cancel() {
        text = ""
        focused = false
        browser.leaveNewTabPage()
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
