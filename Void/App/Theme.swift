import SwiftUI
import AppKit

/// The five accent colors offered in Settings → Général → Couleur.
/// Each tone was checked against Void's backgrounds (WCAG): the light/dark tones reach at least
/// 4.5:1 as text or icon on the chrome, page and selection backgrounds of their theme, and white
/// reaches at least 5.5:1 on the fill tone used by primary buttons.
enum AccentChoice: String, CaseIterable, Identifiable {
    case violet, blue, green, orange, pink
    var id: String { rawValue }

    var label: String {
        switch self {
        case .violet: "Violet"
        case .blue: "Bleu"
        case .green: "Vert"
        case .orange: "Orange"
        case .pink: "Rose"
        }
    }

    /// Text / icon tone on light backgrounds; also the fill of primary buttons (white label).
    var lightHex: UInt32 {
        switch self {
        case .violet: 0x5B4BE0
        case .blue: 0x1F5FD1
        case .green: 0x12703A
        case .orange: 0xA84400
        case .pink: 0xC21F68
        }
    }

    /// Text / icon tone on dark backgrounds.
    var darkHex: UInt32 {
        switch self {
        case .violet: 0x9D8FFF
        case .blue: 0x6AA8FF
        case .green: 0x4FCF7F
        case .orange: 0xFF9E4A
        case .pink: 0xFF7EB6
        }
    }
}

/// Void's palette — the only place where colors are defined. Every color adapts to the current
/// appearance (dark by default); the accent follows Settings → Général → Couleur, live.
enum Theme {
    static let chrome = dynamic(light: chromeLight, dark: chromeDark)
    static let surface = dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x17171C))
    static let elevated = dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x1D1D23))
    static let hover = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.055))
    static let selection = dynamic(light: NSColor(white: 1, alpha: 0.95), dark: NSColor(white: 1, alpha: 0.10))
    static let stroke = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    static let primaryText = dynamic(light: NSColor(hex: 0x131316), dark: NSColor(hex: 0xECECF1))
    static let secondaryText = dynamic(light: NSColor(hex: 0x62626B), dark: NSColor(hex: 0x8B8B96))
    static let success = dynamic(light: NSColor(hex: 0x1E7B34), dark: NSColor(hex: 0x5AD27A))
    static let danger = dynamic(light: NSColor(hex: 0xC4262E), dark: NSColor(hex: 0xFF6B6B))
    static let switchOff = dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.18))
    static let switchKnob = Color.white
    static let shadow = Color.black
    static let scrim = Color.black.opacity(0.28)

    /// Window background behind the chrome (AppKit side of `chrome`).
    static let chromeNS = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? chromeDark : chromeLight }
    private static let chromeLight = NSColor(hex: 0xE9E9EE)
    private static let chromeDark = NSColor(hex: 0x0B0B0E)

    // MARK: Accent

    private struct AccentPalette {
        let accent: Color, fill: Color, soft: Color
    }

    private static let palettes: [AccentChoice: AccentPalette] = Dictionary(uniqueKeysWithValues: AccentChoice.allCases.map { choice in
        (choice, AccentPalette(
            accent: dynamic(light: NSColor(hex: choice.lightHex), dark: NSColor(hex: choice.darkHex)),
            fill: Color(nsColor: NSColor(hex: choice.lightHex)),
            soft: dynamic(light: NSColor(hex: choice.lightHex, alpha: 0.13), dark: NSColor(hex: choice.darkHex, alpha: 0.2))))
    })

    /// Icons, active controls, selected tab marker, switches, focus rings, links.
    @MainActor static var accent: Color { palettes[AppSettings.shared.accent]!.accent }
    /// Solid fill behind white text (primary buttons) — same tone in both themes.
    @MainActor static var accentFill: Color { palettes[AppSettings.shared.accent]!.fill }
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

    static let privateChrome = Color(nsColor: privateChromeNS)
    static let privateChromeNS = NSColor(hex: 0x23262F)
    static let privateBadge = Color(nsColor: NSColor(white: 1, alpha: 0.14))
    static let privateBadgeText = Color(nsColor: NSColor(white: 1, alpha: 0.92))

    // MARK: Floating video player (plan B)

    static let videoBackgroundNS = NSColor.black
    static let videoControlNS = NSColor.white

    // MARK: Logo (brand colors, fixed)

    static let logoGradient = [NSColor(hex: 0xF4F1FF), NSColor(hex: 0x9D8FFF), NSColor(hex: 0x4B3FD0)].map { Color(nsColor: $0) }
    static let logoGlow = Color(nsColor: NSColor(hex: 0x9D8FFF, alpha: 0.55))
    static let logoCore = Color(nsColor: NSColor(hex: 0x07070A))

    // MARK: Reader mode stylesheet colors

    static let readerCSS = (light: "--bg:#FBFAF7; --fg:#1B1B1F; --muted:#6C6C75; --rule:rgba(0,0,0,.08);",
                            dark: "--bg:#111115; --fg:#E4E4EA; --muted:#8B8B96; --rule:rgba(255,255,255,.08);")

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.16)

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
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
        content.buttonStyle(.borderedProminent).tint(Theme.accentFill)
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
    var help: String = ""
    var active: Bool = false
    var disabled: Bool = false
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering && !disabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
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
