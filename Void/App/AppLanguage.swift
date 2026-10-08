import Foundation
#if os(macOS)
import AppKit
#endif

/// The language of Void's interface: the system's by default (French, or English for any other
/// language), or the one chosen in Settings → Général. The choice is the app's own AppleLanguages,
/// which is also what System Settings → Langue et région → Apps (Mac) and Réglages → Void → Langue
/// (iOS) change; it applies from the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, fr, en
    var id: String { rawValue }

    /// Each language is named in itself, so that it can be found whatever the current one.
    var label: String {
        switch self {
        case .system: String(localized: "Langue du système")
        case .fr: "Français"
        case .en: "English"
        }
    }

    private static let key = "AppleLanguages"

    /// The choice saved for Void alone (UserDefaults would also return the system's list).
    static var current: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = languages.first else { return .system }
        return first.hasPrefix("fr") ? .fr : first.hasPrefix("en") ? .en : .system
    }

    static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// The language the interface shows since launch.
    static let shown = Bundle.main.preferredLocalizations.first ?? "en"

    /// The language this choice gives the interface.
    var resolved: String {
        switch self {
        case .fr, .en: rawValue
        case .system:
            Bundle.preferredLocalizations(from: Self.supported, forPreferences: Self.systemLanguages).first ?? "en"
        }
    }

    /// Whether Void must start again to show this choice.
    var needsRelaunch: Bool { resolved != Self.shown }

    private static var supported: [String] { Bundle.main.localizations.filter { $0 != "Base" } }

    /// The system's languages, whatever was chosen for Void.
    private static var systemLanguages: [String] {
        #if os(macOS)
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String] ?? Locale.preferredLanguages
        #else
        Locale.preferredLanguages
        #endif
    }

    #if os(macOS)
    private static var relaunchRequested = false

    /// Quits, then opens Void again once this copy has really gone (Void runs only once).
    @MainActor
    static func relaunch() {
        relaunchRequested = true
        NSApp.terminate(nil)
        relaunchRequested = false   // only reached when quitting was cancelled
    }

    /// Called as Void quits.
    static func relaunchIfRequested() {
        guard relaunchRequested else { return }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                            Bundle.main.bundlePath]
        try? waiter.run()
    }
    #endif
}
