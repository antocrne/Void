import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum TabLayout: String, CaseIterable, Identifiable {
    case sidebar, top
    var id: String { rawValue }
    var label: String { self == .sidebar ? String(localized: "Barre latérale") : String(localized: "Barre d'onglets en haut") }
}

enum TabIconStyle: String, CaseIterable, Identifiable {
    case letters, favicons
    var id: String { rawValue }
    var label: String { self == .letters ? String(localized: "Lettres") : String(localized: "Icônes de sites") }
}

/// Who offers to save and fill passwords: Void (macOS keychain) or another password manager.
enum PasswordManagerChoice: String, CaseIterable, Identifiable {
    /// Void, unless a password manager extension is installed.
    case automatic, void, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: String(localized: "Automatique")
        case .void:
            #if os(macOS)
            String(localized: "Void (trousseau macOS)")
            #else
            String(localized: "Void (trousseau de l'appareil)")
            #endif
        case .other: String(localized: "Un autre gestionnaire")
        }
    }
}

/// How long a page stays in the history after its last visit.
enum HistoryRetention: Int, CaseIterable, Identifiable {
    case year = 365, sixMonths = 182, ninetyDays = 90, thirtyDays = 30
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .year: String(localized: "1 an")
        case .sixMonths: String(localized: "6 mois")
        case .ninetyDays: String(localized: "90 jours")
        case .thirtyDays: String(localized: "30 jours")
        }
    }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dark: String(localized: "Sombre")
        case .light: String(localized: "Clair")
        case .system: String(localized: "Système")
        }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, ecosia, qwant, startpage, kagi, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        case .qwant: "Qwant"
        case .startpage: "Startpage"
        case .kagi: "Kagi"
        case .custom: String(localized: "Personnalisé")
        }
    }

    /// `%s` is replaced by the percent-encoded query.
    var template: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .duckduckgo: "https://duckduckgo.com/?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .qwant: "https://www.qwant.com/?q=%s"
        case .startpage: "https://www.startpage.com/do/search?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        case .custom: ""
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let defaults = UserDefaults.standard

    var tabLayout: TabLayout { didSet { defaults.set(tabLayout.rawValue, forKey: "tabLayout") } }
    var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: "theme"); applyAppearance() } }
    var searchEngine: SearchEngine { didSet { defaults.set(searchEngine.rawValue, forKey: "searchEngine") } }
    var customSearchTemplate: String { didSet { defaults.set(customSearchTemplate, forKey: "customSearchTemplate") } }
    var sidebarVisible: Bool { didSet { defaults.set(sidebarVisible, forKey: "sidebarVisible") } }
    var restoreTabs: Bool { didSet { defaults.set(restoreTabs, forKey: "restoreTabs") } }
    var autoPiP: Bool { didSet { defaults.set(autoPiP, forKey: "autoPiP") } }
    /// Mac: a video call goes into a floating window when its tab is left.
    var autoMeetingPiP: Bool { didSet { defaults.set(autoMeetingPiP, forKey: "autoMeetingPiP") } }
    var adBlockEnabled: Bool { didSet { defaults.set(adBlockEnabled, forKey: "adBlockEnabled"); ContentRules.shared.reload() } }
    var adBlockAllowlist: [String] { didSet { defaults.set(adBlockAllowlist, forKey: "adBlockAllowlist"); ContentRules.shared.reload() } }
    var extensionsEnabled: Bool {
        didSet {
            defaults.set(extensionsEnabled, forKey: "extensionsEnabled")
            #if os(macOS)
            if #available(macOS 15.4, *) {
                if extensionsEnabled { ExtensionManager.shared.start() } else { ExtensionManager.shared.stop() }
            }
            #endif
        }
    }
    var neverSavePasswordHosts: [String] { didSet { defaults.set(neverSavePasswordHosts, forKey: "neverSavePasswordHosts") } }
    var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: "historyRetention"); HistoryStore.shared.prune() }
    }
    var formAutofillEnabled: Bool { didSet { defaults.set(formAutofillEnabled, forKey: "formAutofillEnabled") } }
    /// Pages may start playing only without sound (applies to tabs opened afterwards).
    var blockAutoplayWithSound: Bool { didSet { defaults.set(blockAutoplayWithSound, forKey: "blockAutoplayWithSound") } }
    var passwordManager: PasswordManagerChoice { didSet { defaults.set(passwordManager.rawValue, forKey: "passwordManager") } }
    var extensionsInPrivate: Bool {
        didSet {
            defaults.set(extensionsInPrivate, forKey: "extensionsInPrivate")
            #if os(macOS)
            if #available(macOS 15.4, *) { ExtensionManager.shared.applyPrivateAccess() }
            #endif
        }
    }

    // Onglets
    /// Sidebar hidden until the pointer pushes against the left edge (⌘S).
    var sidebarAutoHide: Bool { didSet { defaults.set(sidebarAutoHide, forKey: "sidebarAutoHide") } }
    var sidebarWidth: Double { didSet { defaults.set(sidebarWidth, forKey: "sidebarWidth") } }
    var tabIconStyle: TabIconStyle { didSet { defaults.set(tabIconStyle.rawValue, forKey: "tabIconStyle") } }
    var showBookmarksBar: Bool { didSet { defaults.set(showBookmarksBar, forKey: "showBookmarksBar") } }
    var showReadingProgress: Bool { didSet { defaults.set(showReadingProgress, forKey: "showReadingProgress") } }
    var sleepInactiveTabs: Bool { didSet { defaults.set(sleepInactiveTabs, forKey: "sleepInactiveTabs") } }

    var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    /// Tint of the window's frame (see ChromeTint.swift).
    var chromeTint: ChromeTint { didSet { defaults.set(chromeTint.rawValue, forKey: "chromeTint") } }
    var chromeTintIntensity: Double { didSet { defaults.set(chromeTintIntensity, forKey: "chromeTintIntensity") } }
    var chromeTintGradient: Bool { didSet { defaults.set(chromeTintGradient, forKey: "chromeTintGradient") } }
    /// The first-launch personalization was completed or skipped.
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") } }
    /// nil = ~/Downloads (on iOS: the app's Documents folder, shown in Files).
    var downloadFolderPath: String? { didSet { defaults.set(downloadFolderPath, forKey: "downloadFolderPath") } }
    /// Asks where to save each download (on iOS: once downloaded, where to put it in Files).
    var askDownloadLocation: Bool { didSet { defaults.set(askDownloadLocation, forKey: "askDownloadLocation") } }
    /// « Partager aussi le son » in the screen sharing question, as last answered (Mac).
    var shareScreenAudio: Bool { didSet { defaults.set(shareScreenAudio, forKey: "shareScreenAudio") } }

    static let defaultSidebarWidth: Double = 252
    static let sidebarWidthRange: ClosedRange<Double> = 200...460

    private init() {
        let d = UserDefaults.standard
        tabLayout = TabLayout(rawValue: d.string(forKey: "tabLayout") ?? "") ?? .sidebar
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .dark
        searchEngine = SearchEngine(rawValue: d.string(forKey: "searchEngine") ?? "") ?? .google
        customSearchTemplate = d.string(forKey: "customSearchTemplate") ?? "https://example.com/search?q=%s"
        sidebarVisible = d.object(forKey: "sidebarVisible") as? Bool ?? true
        restoreTabs = d.object(forKey: "restoreTabs") as? Bool ?? true
        autoPiP = d.object(forKey: "autoPiP") as? Bool ?? true
        autoMeetingPiP = d.object(forKey: "autoMeetingPiP") as? Bool ?? true
        adBlockEnabled = d.object(forKey: "adBlockEnabled") as? Bool ?? true
        adBlockAllowlist = d.stringArray(forKey: "adBlockAllowlist") ?? []
        extensionsEnabled = d.object(forKey: "extensionsEnabled") as? Bool ?? false
        neverSavePasswordHosts = d.stringArray(forKey: "neverSavePasswordHosts") ?? []
        historyRetention = HistoryRetention(rawValue: d.integer(forKey: "historyRetention")) ?? .year
        formAutofillEnabled = d.object(forKey: "formAutofillEnabled") as? Bool ?? true
        blockAutoplayWithSound = d.object(forKey: "blockAutoplayWithSound") as? Bool ?? false
        passwordManager = PasswordManagerChoice(rawValue: d.string(forKey: "passwordManager") ?? "") ?? .automatic
        extensionsInPrivate = d.object(forKey: "extensionsInPrivate") as? Bool ?? false
        sidebarAutoHide = d.object(forKey: "sidebarAutoHide") as? Bool ?? false
        sidebarWidth = d.object(forKey: "sidebarWidth") as? Double ?? Self.defaultSidebarWidth
        tabIconStyle = TabIconStyle(rawValue: d.string(forKey: "tabIconStyle") ?? "") ?? .favicons
        showBookmarksBar = d.object(forKey: "showBookmarksBar") as? Bool ?? false
        showReadingProgress = d.object(forKey: "showReadingProgress") as? Bool ?? true
        sleepInactiveTabs = d.object(forKey: "sleepInactiveTabs") as? Bool ?? true
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .violet
        chromeTint = ChromeTint(rawValue: d.string(forKey: "chromeTint") ?? "") ?? .none
        chromeTintIntensity = d.object(forKey: "chromeTintIntensity") as? Double ?? ChromeLook.amountRange.upperBound
        chromeTintGradient = d.object(forKey: "chromeTintGradient") as? Bool ?? true
        onboardingCompleted = d.bool(forKey: "onboardingCompleted")
        downloadFolderPath = d.string(forKey: "downloadFolderPath")
        shareScreenAudio = d.bool(forKey: "shareScreenAudio")
        #if os(macOS)
        // Mac: the "Enregistrer sous" panel for each file, unless turned off.
        askDownloadLocation = d.object(forKey: "askDownloadLocation") as? Bool ?? true
        #else
        askDownloadLocation = d.bool(forKey: "askDownloadLocation")
        #endif
    }

    var chromeLook: ChromeLook {
        let range = ChromeLook.amountRange
        return ChromeLook(tint: chromeTint,
                          amount: min(range.upperBound, max(range.lowerBound, chromeTintIntensity)), gradient: chromeTintGradient)
    }

    func searchURL(for query: String) -> URL? {
        let template = searchEngine == .custom ? customSearchTemplate : searchEngine.template
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    var downloadFolder: URL {
        if let downloadFolderPath, FileManager.default.fileExists(atPath: downloadFolderPath) {
            return URL(fileURLWithPath: downloadFolderPath, isDirectory: true)
        }
        #if os(macOS)
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    func applyAppearance() {
        #if os(macOS)
        switch theme {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
        #else
        // Every window, sheets and web views included (a page's prefers-color-scheme follows).
        let style: UIUserInterfaceStyle = switch theme {
        case .dark: .dark
        case .light: .light
        case .system: .unspecified
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
        #endif
    }

    func toggleAdBlock(for host: String) {
        let h = host.voidNormalizedHost
        if let i = adBlockAllowlist.firstIndex(of: h) { adBlockAllowlist.remove(at: i) } else { adBlockAllowlist.append(h) }
    }

    func isAdBlockActive(on host: String?) -> Bool {
        guard adBlockEnabled else { return false }
        guard let host else { return true }
        return !adBlockAllowlist.contains(host.voidNormalizedHost)
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

extension String {
    /// Lower-cased host without a leading "www.".
    var voidNormalizedHost: String {
        let h = lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}
