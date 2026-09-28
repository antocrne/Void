import AppKit
import Observation

enum TabLayout: String, CaseIterable, Identifiable {
    case sidebar, top
    var id: String { rawValue }
    var label: String { self == .sidebar ? "Barre latérale" : "Barre d'onglets en haut" }
}

enum TabIconStyle: String, CaseIterable, Identifiable {
    case letters, favicons
    var id: String { rawValue }
    var label: String { self == .letters ? "Lettres" : "Icônes de sites" }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dark: "Sombre"
        case .light: "Clair"
        case .system: "Système"
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
        case .custom: "Personnalisé"
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
    var adBlockEnabled: Bool { didSet { defaults.set(adBlockEnabled, forKey: "adBlockEnabled"); ContentRules.shared.reload() } }
    var adBlockAllowlist: [String] { didSet { defaults.set(adBlockAllowlist, forKey: "adBlockAllowlist"); ContentRules.shared.reload() } }
    var extensionsEnabled: Bool { didSet { defaults.set(extensionsEnabled, forKey: "extensionsEnabled") } }
    var neverSavePasswordHosts: [String] { didSet { defaults.set(neverSavePasswordHosts, forKey: "neverSavePasswordHosts") } }
    var extensionsInPrivate: Bool {
        didSet {
            defaults.set(extensionsInPrivate, forKey: "extensionsInPrivate")
            if #available(macOS 15.4, *) { ExtensionManager.shared.applyPrivateAccess() }
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
    /// The first-launch personalization was completed or skipped.
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") } }
    /// nil = ~/Downloads.
    var downloadFolderPath: String? { didSet { defaults.set(downloadFolderPath, forKey: "downloadFolderPath") } }

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
        adBlockEnabled = d.object(forKey: "adBlockEnabled") as? Bool ?? true
        adBlockAllowlist = d.stringArray(forKey: "adBlockAllowlist") ?? []
        extensionsEnabled = d.object(forKey: "extensionsEnabled") as? Bool ?? false
        neverSavePasswordHosts = d.stringArray(forKey: "neverSavePasswordHosts") ?? []
        extensionsInPrivate = d.object(forKey: "extensionsInPrivate") as? Bool ?? false
        sidebarAutoHide = d.object(forKey: "sidebarAutoHide") as? Bool ?? false
        sidebarWidth = d.object(forKey: "sidebarWidth") as? Double ?? Self.defaultSidebarWidth
        tabIconStyle = TabIconStyle(rawValue: d.string(forKey: "tabIconStyle") ?? "") ?? .favicons
        showBookmarksBar = d.object(forKey: "showBookmarksBar") as? Bool ?? false
        showReadingProgress = d.object(forKey: "showReadingProgress") as? Bool ?? true
        sleepInactiveTabs = d.object(forKey: "sleepInactiveTabs") as? Bool ?? true
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .violet
        onboardingCompleted = d.bool(forKey: "onboardingCompleted")
        downloadFolderPath = d.string(forKey: "downloadFolderPath")
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
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func applyAppearance() {
        switch theme {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
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
