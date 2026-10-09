import SwiftUI

/// The five accent colors offered in Settings → Général → Couleur, in pastel tones (OKLCH:
/// lightness 0.74 and chroma 0.095 for the light theme, 0.80 and about 0.09 for the dark one).
/// A deliberate choice of softness over contrast in the light theme: there an accent text or
/// icon reaches only about 2:1 on the chrome; in the dark theme, at least 8:1. Labels on an accent
/// fill (primary buttons, badges) are dark (`Theme.onAccent`, at least 7.5:1), never white.
enum AccentChoice: String, CaseIterable, Identifiable {
    case violet, blue, green, orange, pink
    var id: String { rawValue }

    var label: String {
        switch self {
        case .violet: String(localized: "Violet")
        case .blue: String(localized: "Bleu")
        case .green: String(localized: "Vert")
        case .orange: String(localized: "Orange")
        case .pink: String(localized: "Rose")
        }
    }

    /// Text / icon tone on light backgrounds; also the fill of primary buttons (dark label).
    var lightHex: UInt32 {
        switch self {
        case .violet: 0xA7A2E4
        case .blue: 0x84ADE7
        case .green: 0x7BBC8E
        case .orange: 0xD89C6D
        case .pink: 0xDB92AE
        }
    }

    /// Text / icon tone on dark backgrounds.
    var darkHex: UInt32 {
        switch self {
        case .violet: 0xBAB5F4
        case .blue: 0x9EC0F0
        case .green: 0x91CFA3
        case .orange: 0xE7B188
        case .pink: 0xEEA5C1
        }
    }
}

/// Void's palette — the only place where colors are defined (the frame's tints are computed in
/// ChromeTint.swift). Every color adapts to the current appearance (dark by default); the accent
/// follows Settings → Général → Couleur and the frame Settings → Général → Teinte, live.
enum Theme {
    /// The window's frame (sidebar, bars, around the page), flat: neutral or tinted.
    @MainActor static var chrome: Color { Color(platformColor: chromeNS) }
    /// A tinted frame over the blurred desktop (Mac): lightly translucent.
    static let translucentChromeOpacity = 0.82
    static let surface = dynamic(light: PlatformColor(hex: 0xFFFFFF), dark: PlatformColor(hex: 0x17171C))
    static let elevated = dynamic(light: PlatformColor(hex: 0xFFFFFF), dark: PlatformColor(hex: 0x1D1D23))
    static let hover = dynamic(light: PlatformColor(white: 0, alpha: 0.05), dark: PlatformColor(white: 1, alpha: 0.055))
    static let selection = dynamic(light: PlatformColor(white: 1, alpha: 0.95), dark: PlatformColor(white: 1, alpha: 0.10))
    static let stroke = dynamic(light: PlatformColor(white: 0, alpha: 0.08), dark: PlatformColor(white: 1, alpha: 0.08))
    static let primaryText = dynamic(light: PlatformColor(hex: 0x131316), dark: PlatformColor(hex: 0xECECF1))
    /// Cool grey on the neutral frame; warm grey, lighter in the dark theme, on a tinted one (its
    /// warm base and up to 20 % of color): at least 4.5:1 on the frame in both cases.
    @MainActor static var secondaryText: Color {
        AppSettings.shared.chromeTint == .none ? secondaryTextNeutral : secondaryTextWarm
    }
    private static let secondaryTextNeutral = dynamic(light: PlatformColor(hex: 0x62626B), dark: PlatformColor(hex: 0x8B8B96))
    private static let secondaryTextWarm = dynamic(light: PlatformColor(hex: 0x5E5A55), dark: PlatformColor(hex: 0xBCB7B0))
    static let success = dynamic(light: PlatformColor(hex: 0x1E7B34), dark: PlatformColor(hex: 0x5AD27A))
    static let danger = dynamic(light: PlatformColor(hex: 0xC4262E), dark: PlatformColor(hex: 0xFF6B6B))
    static let switchOff = dynamic(light: PlatformColor(white: 0, alpha: 0.14), dark: PlatformColor(white: 1, alpha: 0.18))
    static let switchKnob = Color.white
    static let shadow = Color.black
    static let scrim = Color.black.opacity(0.28)

    /// The tint over the blurred desktop, on the new-tab page: frosted, not clear.
    static let frostedTintOpacity = 0.72
    /// Window background behind the chrome (AppKit side of `chrome`).
    @MainActor static var chromeNS: PlatformColor { AppSettings.shared.chromeLook.color }

    // MARK: Accent

    private struct AccentPalette {
        let accent: Color, fill: Color, soft: Color
    }

    private static let palettes: [AccentChoice: AccentPalette] = Dictionary(uniqueKeysWithValues: AccentChoice.allCases.map { choice in
        (choice, AccentPalette(
            accent: dynamic(light: PlatformColor(hex: choice.lightHex), dark: PlatformColor(hex: choice.darkHex)),
            fill: Color(platformColor: PlatformColor(hex: choice.lightHex)),
            soft: dynamic(light: PlatformColor(hex: choice.lightHex, alpha: 0.28), dark: PlatformColor(hex: choice.darkHex, alpha: 0.2))))
    })

    /// Icons, active controls, selected tab marker, switches, focus rings, links.
    @MainActor static var accent: Color { palettes[AppSettings.shared.accent]!.accent }
    /// Solid fill behind `onAccent` text (primary buttons, badges) — same tone in both themes.
    @MainActor static var accentFill: Color { palettes[AppSettings.shared.accent]!.fill }
    /// Text and symbols on `accentFill` / `accent` fills: dark, the pastel tones being light.
    static let onAccent = Color(platformColor: PlatformColor(hex: 0x131316))
    /// Tinted background: reading progress, highlighted menu rows, letter tiles.
    @MainActor static var accentSoft: Color { palettes[AppSettings.shared.accent]!.soft }

    static func swatch(_ choice: AccentChoice) -> Color { palettes[choice]!.accent }

    /// Accent for HTML documents Void renders itself (reader mode), as CSS hex (light, dark).
    @MainActor static var accentCSS: (light: String, dark: String) {
        let choice = AppSettings.shared.accent
        return (String(format: "#%06X", choice.lightHex), String(format: "#%06X", choice.darkHex))
    }

    // MARK: Private windows
    // Deliberately independent of the accent: a private window must be recognizable whatever
    // color was chosen. Its chrome is always dark slate (and rendered in dark appearance).

    static let privateChrome = Color(platformColor: privateChromeNS)
    static let privateChromeNS = PlatformColor(hex: 0x23262F)
    static let privateBadge = Color(platformColor: PlatformColor(white: 1, alpha: 0.14))
    static let privateBadgeText = Color(platformColor: PlatformColor(white: 1, alpha: 0.92))

    // MARK: Floating video player (plan B)

    static let videoBackgroundNS = PlatformColor.black
    static let videoControlNS = PlatformColor.white

    // MARK: Logo (brand colors, fixed)

    static let logoGradient = [PlatformColor(hex: 0xF4F1FF), PlatformColor(hex: 0x9D8FFF), PlatformColor(hex: 0x4B3FD0)].map { Color(platformColor: $0) }
    static let logoGlow = Color(platformColor: PlatformColor(hex: 0x9D8FFF, alpha: 0.55))
    static let logoCore = Color(platformColor: PlatformColor(hex: 0x07070A))

    // MARK: Reader mode stylesheet colors

    static let readerCSS = (light: "--bg:#FBFAF7; --fg:#1B1B1F; --muted:#6C6C75; --rule:rgba(0,0,0,.08);",
                            dark: "--bg:#111115; --fg:#E4E4EA; --muted:#8B8B96; --rule:rgba(255,255,255,.08);")

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.16)

    static func dynamic(light: PlatformColor, dark: PlatformColor) -> Color {
        Color(platformColor: .voidDynamic(light: light, dark: dark))
    }
}

extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255, green = CGFloat((hex >> 8) & 0xFF) / 255, blue = CGFloat(hex & 0xFF) / 255
        #if os(macOS)
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        self.init(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }
}

extension View {
    /// Primary button: accent fill with a white label (contrast checked for every accent).
    func voidPrimaryButton() -> some View {
        modifier(PrimaryButtonModifier())
    }

    /// Text field whose focus ring follows the accent color (the system ring follows the
    /// macOS accent, not Void's).
    func voidTextField() -> some View {
        modifier(AccentTextField())
    }
}

private struct PrimaryButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(PrimaryButtonStyle())
    }
}

/// The system's prominent button draws a white label, unreadable on the pastel accents.
private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    #if os(macOS)
    private static let height: CGFloat = 22, padding: CGFloat = 10, radius: CGFloat = 6
    #else
    private static let height: CGFloat = 36, padding: CGFloat = 16, radius: CGFloat = 10
    #endif

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Self.padding)
            .frame(minHeight: Self.height)
            .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(Theme.accentFill)
                .brightness(configuration.isPressed ? -0.08 : 0))
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct AccentTextField: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .focusEffectDisabled()
            .padding(.horizontal, 7)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(focused ? Theme.accent : Theme.stroke, lineWidth: focused ? 2 : 1))
            .animation(Theme.quick, value: focused)
    }
}

/// Switch drawn with Void's accent. The system switch follows the macOS accent color (and turns
/// grey in inactive windows), so it can't show the color chosen in Settings.
struct AccentSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            Button { withAnimation(Theme.quick) { configuration.isOn.toggle() } } label: {
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : Theme.switchOff)
                    .frame(width: 32, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Theme.switchKnob)
                            .shadow(color: Theme.shadow.opacity(0.25), radius: 1, y: 0.5)
                            .padding(2)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "activé" : "désactivé")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// The Void mark: a dark disc eclipsing a luminous ring.
struct VoidLogo: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: Theme.logoGradient, startPoint: .bottomLeading, endPoint: .topTrailing))
                .shadow(color: Theme.logoGlow, radius: size * 0.12)
            Circle()
                .fill(Theme.logoCore)
                .frame(width: size * 0.86, height: size * 0.86)
                .offset(x: size * 0.045, y: -size * 0.045)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Void")
    }
}

/// Small icon-only button used throughout the chrome.
struct ChromeButton: View {
    let symbol: String
    var help: LocalizedStringKey = ""
    /// In place of `help`, a text not to translate (a space's name).
    var verbatimHelp: String?
    var active: Bool = false
    var disabled: Bool = false
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    #if os(macOS)
    private static let side: CGFloat = 26, symbolScale: CGFloat = 1
    #else
    /// A finger needs a larger target than a pointer.
    private static let side: CGFloat = 38, symbolScale: CGFloat = 1.35
    #endif

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * Self.symbolScale, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.secondaryText)
                .frame(width: Self.side, height: Self.side)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering && !disabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(verbatimHelp.map { Text($0) } ?? Text(help))
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }
}

/// "Privé" badge shown in the chrome of private windows.
struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash.fill").font(.system(size: 9.5, weight: .semibold))
            Text("Privé").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.privateBadgeText)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Theme.privateBadge))
        .help("Fenêtre privée : ni historique, ni cookies, ni session conservés après fermeture")
        .accessibilityLabel("Fenêtre privée")
    }
}
