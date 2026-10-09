import SwiftUI

/// First launch: a few choices so Void looks the way the user wants. Every choice is a regular
/// setting, applied at once (the browser behind the card shows it) and editable later in Settings.
/// Shown in the main window while `BrowserModel.onboardingStep` is set.
struct OnboardingView: View {
    let step: Int
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings

    static let stepCount = 5

    var body: some View {
        ZStack {
            Theme.scrim
                .contentShape(Rectangle())
                .onTapGesture {}   // the browser behind is a preview, not clickable yet

            VStack(spacing: 0) {
                Group {
                    switch step {
                    case 0: WelcomeStep()
                    case 1: AppearanceStep()
                    case 2: TabsStep()
                    case 3: SidebarStep()
                    default: ReadyStep()
                    }
                }
                .id(step)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
                .padding(28)
                // Same height for every step, so the buttons don't jump.
                .frame(maxWidth: .infinity, minHeight: 330, alignment: step == 0 ? .center : .topLeading)

                Divider().opacity(0.6)
                footer
            }
            .frame(width: 620)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
            .shadow(color: Theme.shadow.opacity(0.35), radius: 30, y: 12)
            .animation(Theme.spring, value: step)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<Self.stepCount, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Theme.accent : Theme.switchOff)
                        .frame(width: i == step ? 16 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Étape \(step + 1) sur \(Self.stepCount)")
            Spacer()
            if step == 0 {
                Button("Garder les réglages par défaut") { browser.finishOnboarding() }
            } else if step < Self.stepCount - 1 {
                Button("Passer") { browser.finishOnboarding() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                Button("Retour") { browser.onboardingStep = step - 1 }
            }
            Button(primaryTitle) {
                if step == Self.stepCount - 1 { browser.finishOnboarding() } else { browser.onboardingStep = step + 1 }
            }
            .voidPrimaryButton()
            .keyboardShortcut(.defaultAction)
            // Esc: keep what's chosen so far and start browsing.
            Button("") { browser.finishOnboarding() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case 0: "Personnaliser"
        case Self.stepCount - 1: "Commencer à naviguer"
        default: "Continuer"
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 16) {
            VoidLogo(size: 64)
            Text("Bienvenue dans Void").font(.system(size: 24, weight: .bold))
            Text("Quelques choix pour que Void vous ressemble : apparence, onglets, barre latérale. Chaque choix s'applique tout de suite au navigateur, derrière, et reste modifiable dans Réglages (⌘,).")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct AppearanceStep: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Apparence", subtitle: "Le thème de l'interface, la couleur d'accent (onglet actif, interrupteurs, boutons) et la teinte de la fenêtre.")
            HStack(spacing: 12) {
                ForEach(ThemeChoice.allCases) { choice in
                    OptionCard(title: Text(choice.label), selected: settings.theme == choice) {
                        withAnimation(Theme.quick) { settings.theme = choice }
                    } preview: {
                        switch choice {
                        case .dark: MiniBrowser(layout: settings.tabLayout).environment(\.colorScheme, .dark)
                        case .light: MiniBrowser(layout: settings.tabLayout).environment(\.colorScheme, .light)
                        case .system:
                            HStack(spacing: 0) {
                                MiniBrowser(layout: settings.tabLayout).environment(\.colorScheme, .light)
                                MiniBrowser(layout: settings.tabLayout).environment(\.colorScheme, .dark)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
            HStack {
                Text("Couleur").font(.system(size: 13, weight: .medium))
                Spacer()
                AccentPicker()
            }
            HStack {
                Text("Teinte").font(.system(size: 13, weight: .medium))
                Spacer()
                ChromeTintPicker()
            }
        }
    }
}

private struct TabsStep: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Onglets", subtitle: "Où les ranger, et ce qu'ils montrent à côté du titre.")
            HStack(spacing: 12) {
                OptionCard(title: Text("Barre latérale, à gauche"), selected: settings.tabLayout == .sidebar) {
                    withAnimation(Theme.spring) { settings.tabLayout = .sidebar }
                } preview: { MiniBrowser(layout: .sidebar) }
                OptionCard(title: Text("Barre d'onglets en haut"), selected: settings.tabLayout == .top) {
                    withAnimation(Theme.spring) { settings.tabLayout = .top }
                } preview: { MiniBrowser(layout: .top) }
            }
            HStack(spacing: 12) {
                ForEach(TabIconStyle.allCases) { style in
                    OptionCard(title: Text(style.label), selected: settings.tabIconStyle == style, height: 44) {
                        settings.tabIconStyle = style
                    } preview: { SampleTab(style: style) }
                }
            }
        }
    }
}

private struct SidebarStep: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            if settings.tabLayout == .sidebar {
                StepHeader(title: "Barre latérale", subtitle: "Toujours là, ou cachée pour laisser toute la place à la page.")
                HStack(spacing: 12) {
                    OptionCard(title: Text("Toujours visible"), selected: !settings.sidebarAutoHide) {
                        withAnimation(Theme.spring) { settings.sidebarAutoHide = false; settings.sidebarVisible = true }
                    } preview: { MiniBrowser(layout: .sidebar) }
                    OptionCard(title: Text("Masquée jusqu'au bord"), selected: settings.sidebarAutoHide) {
                        withAnimation(Theme.spring) { settings.sidebarAutoHide = true; settings.sidebarVisible = true }
                    } preview: { MiniBrowser(layout: .sidebar, tabsHidden: true) }
                }
                Text("Masquée : poussez le pointeur contre le bord gauche de la fenêtre pour faire apparaître les onglets. ⌘S bascule à tout moment ; tirez le bord de la barre pour l'élargir.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                StepHeader(title: "Affichage", subtitle: "Ce qui accompagne les onglets.")
            }
            VStack(spacing: 10) {
                Toggle("Afficher la barre de favoris", isOn: $settings.showBookmarksBar.animation(Theme.spring))
                Toggle("Afficher la progression de lecture dans l'onglet actif", isOn: $settings.showReadingProgress)
                Toggle("Mettre en veille les onglets inutilisés depuis 30 minutes", isOn: $settings.sleepInactiveTabs)
            }
            .toggleStyle(AccentSwitchStyle())
            .font(.system(size: 13))
        }
    }
}

private struct ReadyStep: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BrowserModel.self) private var browser
    @State private var isDefault = DefaultBrowser.isDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "C'est prêt", subtitle: "Vous pourrez tout changer dans Réglages (⌘,) → Général et Onglets.")
            VStack(alignment: .leading, spacing: 8) {
                SummaryRow(symbol: "circle.lefthalf.filled", text: "Thème \(settings.theme.label.lowercased()), couleur \(settings.accent.label.lowercased())")
                SummaryRow(symbol: settings.tabLayout == .sidebar ? "sidebar.left" : "rectangle.topthird.inset.filled",
                           text: settings.tabLayout != .sidebar ? "Onglets en haut"
                               : settings.sidebarAutoHide ? "Onglets dans une barre latérale, masquée jusqu'au bord"
                               : "Onglets dans une barre latérale")
                SummaryRow(symbol: "textformat", text: "Les onglets affichent : \(settings.tabIconStyle.label.lowercased())")
                if settings.showBookmarksBar { SummaryRow(symbol: "star", text: "Barre de favoris affichée") }
            }
            HStack(spacing: 10) {
                if isDefault {
                    Label("Void est votre navigateur par défaut", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                } else {
                    Button("Définir Void par défaut") {
                        DefaultBrowser.makeDefault { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isDefault = DefaultBrowser.isDefault }
                        }
                    }
                }
                Button("Importer favoris et mots de passe…") {
                    UserDefaults.standard.set("general", forKey: "settingsPanel")
                    browser.finishOnboarding()
                    browser.openSettingsAction?()
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Building blocks

private struct StepHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct SummaryRow: View {
    let symbol: String
    let text: LocalizedStringKey
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 18) }
            .font(.system(size: 13))
    }
}

/// A selectable card with a small illustration; the choice is outlined with the accent.
private struct OptionCard<Preview: View>: View {
    let title: Text
    let selected: Bool
    var height: CGFloat = 96
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                    title.font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover.opacity(1.8) : Theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tab as it will look: letter tile or site icon, then the title.
private struct SampleTab: View {
    let style: TabIconStyle
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if style == .letters {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(Theme.accentSoft)
                        .overlay(Text("W").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent))
                } else {
                    Image(systemName: "globe.europe.africa.fill")
                        .resizable()
                        .symbolRenderingMode(.multicolor)
                }
            }
            .frame(width: 16, height: 16)
            Text("Wikipédia").font(.system(size: 12.5)).foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.selection))
        .padding(.horizontal, 6)
    }
}

/// A tiny drawing of Void's window in a given layout, using the current theme and accent.
struct MiniBrowser: View {
    let layout: TabLayout
    var tabsHidden = false

    var body: some View {
        ZStack(alignment: .leading) {
            ChromeBackground()
            switch layout {
            case .sidebar where tabsHidden:
                page.padding(0)
                Capsule().fill(Theme.accent).frame(width: 3, height: 26).padding(.leading, 2)
            case .sidebar:
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 3) {
                        lights
                        RoundedRectangle(cornerRadius: 2).fill(Theme.hover).frame(height: 6)
                        ForEach(0..<4, id: \.self) { i in
                            HStack(spacing: 2) {
                                if i == 1 { Capsule().fill(Theme.accent).frame(width: 1.5, height: 5) }
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(i == 1 ? Theme.primaryText.opacity(0.55) : Theme.secondaryText.opacity(0.4))
                                    .frame(height: 3)
                            }
                            .padding(2)
                            .background(RoundedRectangle(cornerRadius: 2).fill(i == 1 ? Theme.selection : .clear))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 34)
                    page
                }
                .padding(4)
            case .top:
                VStack(spacing: 4) {
                    HStack(spacing: 3) {
                        lights
                        RoundedRectangle(cornerRadius: 2).fill(Theme.hover).frame(width: 22, height: 6)
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(i == 0 ? Theme.selection : Theme.hover)
                                .frame(height: 7)
                                .overlay(alignment: .bottom) {
                                    if i == 0 { Capsule().fill(Theme.accent).frame(width: 6, height: 1.5) }
                                }
                        }
                    }
                    page
                }
                .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke))
        .accessibilityHidden(true)
    }

    private var lights: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.secondaryText.opacity(0.45)).frame(width: 3.5, height: 3.5) }
        }
    }

    private var page: some View {
        RoundedRectangle(cornerRadius: tabsHidden ? 0 : 3, style: .continuous)
            .fill(Theme.surface)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.primaryText.opacity(0.5)).frame(width: 30, height: 4)
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1).fill(Theme.secondaryText.opacity(0.3)).frame(height: 2.5)
                    }
                }
                .padding(7)
            }
    }
}

extension BrowserModel {
    /// Closes the first-launch personalization; it won't come back (Settings → Général can replay it).
    func finishOnboarding() {
        AppSettings.shared.onboardingCompleted = true
        onboardingStep = nil
    }
}
