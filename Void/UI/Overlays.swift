import SwiftUI

/// Empty state of a space.
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
            Button { browser.showCommandBar(.newTab) } label: {
                Text("Rechercher ou saisir une adresse")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 320, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.hover))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
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
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 30, weight: .light))
            Text("Cette vidéo est dans le lecteur flottant").font(.system(size: 14, weight: .medium))
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
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .voidFindNext)) { note in
            browser.find(text, backwards: (note.object as? Bool) ?? false)
        }
    }

    private func close() {
        withAnimation(Theme.quick) { browser.findBarVisible = false }
    }
}

extension Notification.Name {
    static let voidFindNext = Notification.Name("VoidFindNext")
}
