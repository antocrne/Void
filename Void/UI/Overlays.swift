import SwiftUI

/// The new-tab page (⌘T), also the empty state of a space: its field opens what is typed in a new
/// tab, with the suggestions of the command bar.
struct NewTabPage: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        VStack(spacing: 22) {
            if browser.isPrivate {
                Image(systemName: "eye.slash.circle")
                    .font(.system(size: 50, weight: .ultraLight))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                VoidLogo(size: 58)
            }
            VStack(spacing: 6) {
                Text(browser.isPrivate ? "Navigation privée" : "Rien ici. C'est voulu.")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(browser.isPrivate
                     ? "Ni historique, ni cookies, ni session : tout disparaît à la fermeture de cette fenêtre."
                     : "⌘T pour ouvrir un onglet · ⌘⇧N pour une fenêtre privée")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            NewTabField()
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

/// The field of the new-tab page. Its suggestions drop down over the page, without moving it.
private struct NewTabField: View {
    @Environment(BrowserModel.self) private var browser
    @State private var text = ""
    @State private var selection = 0
    /// Recomputed when the text changes only: it queries the history database.
    @State private var suggestions: [Suggestion] = []
    @FocusState private var focused: Bool

    private static let height: CGFloat = 42

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: browser.isPrivate ? "eye.slash" : "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(focused ? Theme.accent : Theme.secondaryText)
            TextField(Tab.addressPlaceholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit(commit)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.escape) { escape(); return .handled }
                .onChange(of: text) {
                    selection = 0
                    suggestions = text.isEmpty ? [] : SuggestionEngine.suggestions(for: text, browser: browser)
                }
                // Exchange rates that have just arrived: the conversion typed gets its answer.
                .onChange(of: CurrencyRates.shared.revision) {
                    if !text.isEmpty { suggestions = SuggestionEngine.suggestions(for: text, browser: browser) }
                }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: 520)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(focused ? Theme.elevated : Theme.hover))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        .overlay(alignment: .top) {
            if focused, !suggestions.isEmpty { list.offset(y: Self.height + 6) }
        }
        .zIndex(1)
        .animation(Theme.quick, value: focused)
        // ⌘T again (or ⌘L here): a fresh field, ready to type.
        .onChange(of: browser.newTabFieldRequest, initial: true) {
            text = ""
            DispatchQueue.main.async { focused = true }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionRow(suggestion: suggestion, selected: index == selection)
                        .onTapGesture { run(suggestion) }
                        .onHover { if $0 { selection = index } }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
        .shadow(color: Theme.shadow.opacity(0.25), radius: 20, y: 8)
    }

    private func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selection = (selection + delta + suggestions.count) % suggestions.count
    }

    private func commit() {
        if suggestions.indices.contains(selection) {
            run(suggestions[selection])
        } else if !text.isEmpty {
            browser.navigate(text, mode: .newTab)
        }
    }

    private func run(_ suggestion: Suggestion) {
        text = ""
        suggestion.perform(in: browser, mode: .newTab)
    }

    /// Esc: clears what is typed, then goes back to the tab the page was opened over.
    private func escape() {
        if !text.isEmpty {
            text = ""
        } else if browser.leaveNewTabPage() {
            // Once WebHost has put the tab's web view back in the window.
            DispatchQueue.main.async {
                if let webView = browser.selectedTab?.webView { webView.window?.makeFirstResponder(webView) }
            }
        }
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(toast.message).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.ultraThickMaterial))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .shadow(color: Theme.shadow.opacity(0.25), radius: 14, y: 6)
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
                Text("Enregistrer le mot de passe ?").font(.system(size: 13, weight: .semibold))
            }
            Text("\(prompt.username.isEmpty ? "Compte" : prompt.username) · \(prompt.host)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Text("Stocké dans le trousseau macOS, affiché uniquement après Touch ID.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            HStack {
                Button("Jamais pour ce site") { PasswordManager.shared.neverForHost(prompt, in: browser) }
                Spacer()
                Button("Plus tard") { browser.passwordPrompt = nil }
                Button("Enregistrer") { PasswordManager.shared.save(prompt, in: browser) }
                    .voidPrimaryButton()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
        .shadow(color: Theme.shadow.opacity(0.25), radius: 16, y: 6)
    }
}

struct ErrorOverlay: View {
    let message: String
    let url: URL?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.secondaryText)
            Text("Impossible d'ouvrir la page").font(.system(size: 16, weight: .semibold))
            Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            if let host = url?.host() {
                Text(host).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
            }
            Button("Réessayer", action: retry).keyboardShortcut("r")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

struct FloatingPlaceholder: View {
    var isMeeting = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isMeeting ? "video" : "rectangle.on.rectangle").font(.system(size: 30, weight: .light))
            Text(isMeeting ? "Cette réunion est dans une fenêtre flottante" : "Cette vidéo est dans le lecteur flottant").font(.system(size: 14, weight: .medium))
            Button("Ramener ici") { FloatingPlayer.shared.close() }
        }
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

struct FindBar: View {
    @Environment(BrowserModel.self) private var browser
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            TextField("Rechercher dans la page", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(width: 180)
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit { browser.find(text) }
                .onKeyPress(.escape) { close(); return .handled }
            ChromeButton(symbol: "chevron.up", help: "Précédent (⌘⇧G)", size: 11) { browser.find(text, backwards: true) }
            ChromeButton(symbol: "chevron.down", help: "Suivant (⌘G)", size: 11) { browser.find(text) }
            ChromeButton(symbol: "xmark", help: "Fermer", size: 11, action: close)
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focused ? Theme.accent : Theme.stroke, lineWidth: focused ? 1.5 : 1))
        .shadow(color: Theme.shadow.opacity(0.2), radius: 10, y: 4)
        .onAppear {
            text = browser.lastFindText
            focused = true
        }
    }

    private func close() {
        withAnimation(Theme.quick) { browser.findBarVisible = false }
    }
}

