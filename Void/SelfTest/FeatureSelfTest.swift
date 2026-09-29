#if DEBUG
import AppKit
import Network
import WebKit

/// Automated checks of Void's other features, through the real app code.
///   Void.app/Contents/MacOS/Void -VoidSelfTest features [-VoidSelfTestOut /path/report.md]
/// Uses a throw-away space; settings it changes are restored; nothing is left on disk.
@MainActor
final class FeatureSelfTest {
    private let outputPath: String
    private let browser = BrowserModel.shared
    private var lines: [String] = []
    private var passed = 0
    private var failed = 0

    init(outputPath: String) { self.outputPath = outputPath }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        ok ? (passed += 1) : (failed += 1)
        lines.append("- \(ok ? "✅" : "❌") **\(name)** \(detail.isEmpty ? "" : "— " + detail)")
        NSLog("[Void features] %@ %@ %@", ok ? "PASS" : "FAIL", name, detail)
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    private func waitForLoad(_ tab: Tab, timeout: Double = 20) async {
        let start = Date()
        await sleep(0.8)
        while tab.isLoading && Date().timeIntervalSince(start) < timeout { await sleep(0.25) }
        await sleep(0.5)
    }

    private func htmlTab(_ html: String, in space: Space, base: String = "https://void-selftest.example/") async -> Tab {
        let tab = (space.browser ?? browser).openTab(url: nil, in: space)
        tab.ensureWebView().loadHTMLString(html, baseURL: URL(string: base))
        await waitForLoad(tab)
        return tab
    }

    private func js(_ tab: Tab, _ body: String) async -> Any? { await tab.webView?.voidCall(body) }

    /// `-VoidSelfTestOnly session,adresse,…`: runs only these self-contained sections (quick iteration).
    private static let sections: [String: (FeatureSelfTest, Space) async -> Void] = [
        "session": { t, _ in t.testSessionStore() },
        "onglets": { t, space in await t.testTabLifecycle(in: space) },
        "telechargements": { t, space in await t.testDownloads(in: space) },
        "adresse": { t, space in await t.testAddressSpoofing(in: space) },
        "glisser": { t, space in await t.testTabDrag(in: space) },
        "extensions": { t, space in await t.testExtensions(in: space) },
    ]

    func run() async {
        if let only = UserDefaults.standard.string(forKey: "VoidSelfTestOnly") {
            let space = browser.addSpace(name: "Self-test", icon: "hammer")
            for name in only.split(separator: ",").map(String.init) {
                if let section = Self.sections[name] { await section(self, space) } else { check("Section inconnue : \(name)", false) }
            }
            browser.deleteSpace(space)
            write()
            return
        }
        let settings = AppSettings.shared
        let savedLayout = settings.tabLayout, savedTheme = settings.theme, savedSidebar = settings.sidebarVisible
        let windowList = NSApp.windows.map { "\(type(of: $0))[\($0.title)] visible=\($0.isVisible)" }.joined(separator: ", ")
        NSLog("[Void features] fenêtres au départ : %@ · principale=%@", windowList, browser.window.map { "\($0.title) visible=\($0.isVisible)" } ?? "nil")
        let space = browser.addSpace(name: "Self-test", icon: "hammer")
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 1. Address bar resolution
        check("Adresse : « apple.com » → https", URLResolver.url(from: "apple.com")?.absoluteString == "https://apple.com")
        check("Adresse : « localhost:3000 » → http", URLResolver.url(from: "localhost:3000")?.absoluteString == "http://localhost:3000")
        check("Adresse : « trou noir » → recherche", URLResolver.url(from: "trou noir") == nil
              && settings.searchURL(for: "trou noir")?.absoluteString.contains("trou%20noir") == true)

        // 2. Open in new tab: ⌘-click, target=_blank, context menu
        let links = await htmlTab("""
            <!doctype html><body style="margin:0;font:40px system-ui">
            <a id="a" href="https://example.com/?via=cmdclick" style="display:block;padding:40px">Lien ⌘-clic</a>
            <a id="b" href="https://example.com/?via=blank" target="_blank" style="display:block;padding:40px">Lien _blank</a>
            </body>
            """, in: space)
        let before = space.tabs.count
        await click(links, selector: "#a", modifiers: .command)
        await sleep(1.5)
        let cmdTab = space.tabs.first { $0.url?.absoluteString.contains("via=cmdclick") == true }
        check("⌘-clic ouvre un nouvel onglet (arrière-plan)", cmdTab != nil && browser.selectedTab === links,
              "onglets \(before) → \(space.tabs.count)")
        await click(links, selector: "#b", modifiers: [])
        await sleep(2)
        let blankTab = space.tabs.first { $0.url?.absoluteString.contains("via=blank") == true }
        check("Lien target=_blank ouvre un onglet", blankTab != nil && browser.selectedTab === blankTab)
        browser.select(links)

        // Context menu: core.js reports the link, then the menu is rewritten.
        _ = await js(links, "document.getElementById('a').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true})); return 'ok';")
        await sleep(0.5)
        let wv = links.webView!
        check("Clic droit : lien détecté par core.js", wv.contextLinkURL?.absoluteString == "https://example.com/?via=cmdclick",
              wv.contextLinkURL?.absoluteString ?? "nil")
        let menu = NSMenu()
        let original = NSMenuItem(title: "Open Link in New Window", action: nil, keyEquivalent: "")
        original.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        menu.addItem(original)
        if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            wv.willOpenMenu(menu, with: event)
        }
        let titles = menu.items.map(\.title)
        check("Menu contextuel : « Ouvrir le lien dans un nouvel onglet »", titles.contains("Ouvrir le lien dans un nouvel onglet"))
        check("Menu contextuel : arrière-plan + fenêtre privée (plus d'onglet privé)", titles.contains("Ouvrir dans un onglet en arrière-plan")
              && titles.contains("Ouvrir dans une fenêtre privée") && !titles.contains("Ouvrir dans un onglet privé"))
        if let bg = menu.items.first(where: { $0.title == "Ouvrir dans un onglet en arrière-plan" }), let action = bg.action {
            let count = space.tabs.count
            NSApp.sendAction(action, to: bg.target, from: bg)
            await sleep(0.5)
            check("Menu contextuel : l'onglet s'ouvre", space.tabs.count == count + 1)
        }

        // 3. Pinned tab + ⌘W → sleep
        let pinned = browser.openTab(url: URL(string: "https://example.com/?pinned"), in: space)
        await waitForLoad(pinned)
        browser.togglePin(pinned)
        browser.select(pinned)
        browser.closeCurrentTab()
        check("⌘W sur un onglet épinglé → mis en veille", pinned.isAsleep && space.pinned.contains { $0 === pinned })
        browser.select(pinned)
        await waitForLoad(pinned)
        check("Onglet épinglé réveillé au clic", !pinned.isAsleep && pinned.webView?.url != nil)

        // 4. Per-space storage
        let other = browser.addSpace(name: "Self-test B", icon: "star")
        let a = browser.openTab(url: URL(string: "https://example.com/?space=a"), in: space)
        await waitForLoad(a)
        _ = await js(a, "document.cookie = 'voidtest=spaceA; max-age=120; path=/'; return document.cookie;")
        let b = browser.openTab(url: URL(string: "https://example.com/?space=b"), in: other)
        await waitForLoad(b)
        let cookieA = await js(a, "return document.cookie;") as? String ?? ""
        let cookieB = await js(b, "return document.cookie;") as? String ?? ""
        check("Espaces : stockage séparé (cookie)", cookieA.contains("voidtest=spaceA") && !cookieB.contains("voidtest"), "A=\"\(cookieA)\" B=\"\(cookieB)\"")
        browser.switchSpace(to: space)

        // 4b. Private window (⌘⇧N), other normal window (⌘N)
        let released = await privateWindowChecks(normalTab: a)
        await sleep(2)
        check("Fenêtre privée fermée : modèle et stockage libérés", released.model == nil && released.store == nil,
              "modèle=\(released.model == nil ? "libéré" : "vivant") stockage=\(released.store == nil ? "libéré" : "vivant")")
        let again = BrowserWindows.shared.openPrivateWindow()
        let fresh = again.openTab(url: URL(string: "https://example.com/?private=again"))
        await waitForLoad(fresh)
        let freshCookie = await js(fresh, "return document.cookie;") as? String ?? "?"
        check("Fenêtre privée fermée : rien ne persiste (nouvelle fenêtre sans le cookie)", !freshCookie.contains("voidprivate"), "cookie=\"\(freshCookie)\"")
        await sleep(1)
        check("Seconde fenêtre privée : taille stable", again.window?.frame.size == browser.window?.frame.size,
              again.window.map { NSStringFromSize($0.frame.size) } ?? "-")
        again.window?.performClose(nil)
        await sleep(0.5)
        await secondaryWindowChecks(space: space)
        browser.window?.makeKeyAndOrderFront(nil)

        // 4c. Reading progress + automatic sleep
        await tabSleepChecks(space: space, pinned: pinned, other: a)

        // 5. Ad blocker
        let ads = await htmlTab("""
            <!doctype html><body>
            <img id="ad" src="https://googleads.g.doubleclick.net/pagead/viewthroughconversion/1/?void=1" onload="this.dataset.s=1" onerror="this.dataset.s=0">
            <script id="gtm" src="https://www.googletagmanager.com/gtag/js?id=G-VOIDTEST" onload="this.dataset.s=1" onerror="this.dataset.s=0"></script>
            <img id="ok" src="https://www.w3.org/favicon.ico" onload="this.dataset.s=1" onerror="this.dataset.s=0">
            <ins class="adsbygoogle" id="ins" style="display:block;height:90px">ad</ins>
            </body>
            """, in: space)
        await sleep(4)
        let adState = await js(ads, "const s = id => document.getElementById(id).dataset.s; return [s('ad'), s('gtm'), s('ok'), getComputedStyle(document.getElementById('ins')).display].join(',');") as? String ?? ""
        let parts = adState.split(separator: ",").map(String.init)
        check("Bloqueur : doubleclick bloqué", parts.first == "0", adState)
        check("Bloqueur : Google Tag Manager bloqué", parts.count > 1 && parts[1] == "0")
        check("Bloqueur : ressource légitime chargée", parts.count > 2 && parts[2] == "1")
        check("Bloqueur : règle cosmétique (.adsbygoogle masqué)", parts.count > 3 && parts[3] == "none")

        // 6. Reader mode
        let article = browser.openTab(url: URL(string: "https://fr.wikipedia.org/wiki/Trou_noir"), in: space)
        await waitForLoad(article, timeout: 25)
        ReaderMode.toggle(article)
        await sleep(3)
        check("Mode lecture : article extrait", (article.reader?.words ?? 0) > 800,
              "« \(article.reader?.title ?? "-") », \(article.reader?.words ?? 0) mots, \(article.reader?.html.components(separatedBy: "<img").count ?? 1 - 1) images")
        await snapshotWindow("reader")
        ReaderMode.toggle(article)

        // 7. Hide element (real picker: mouse move + click on the <h1>). A local page on a
        // reserved host: the test must not depend on what a real site happens to serve.
        let hiderPage = """
            <!doctype html><body style="margin:0;font:40px system-ui">
            <h1 style="padding:60px 40px;margin:0">Bannière à masquer</h1><p style="padding:40px">Contenu</p>
            </body>
            """
        let hiderBase = "https://void-hider.example/"
        let hide = await htmlTab(hiderPage, in: space, base: hiderBase)
        ElementHider.shared.startPicking(in: hide)
        await sleep(0.8)
        await click(hide, selector: "h1", modifiers: [], move: true)
        await sleep(1.5)
        let rules = ElementHider.shared.rules["void-hider.example"] ?? []
        check("Masquer un élément : sélecteur enregistré", !rules.isEmpty, rules.joined(separator: ", "))
        let hideAgain = await htmlTab(hiderPage, in: space, base: hiderBase)
        await sleep(1)
        let display = await js(hideAgain, "const h = document.querySelector('h1'); return h ? getComputedStyle(h).display : 'absent';") as? String
        check("Masquer un élément : toujours masqué au chargement suivant (règle compilée)", display == "none", "display=\(display ?? "nil")")
        ElementHider.shared.reset(host: "void-hider.example")

        // 7a. Autofill stays on the origin the credentials belong to (no Touch ID here: the
        // injection step is called directly, with a throw-away password).
        let login = await htmlTab("""
            <!doctype html><body><form><input id="u" type="email"><input id="p" type="password"><button>Connexion</button></form></body>
            """, in: space, base: "https://void-login-a.example/")
        await sleep(0.8)
        check("Mots de passe : formulaire rattaché à l'origine du cadre", login.loginHost == "void-login-a.example", login.loginHost ?? "nil")
        let filled = await PasswordManager.shared.inject(account: "moi@void.test", password: "selftest-1", into: login)
        let values = await js(login, "return document.getElementById('u').value + '|' + document.getElementById('p').value;") as? String
        check("Mots de passe : remplissage sur la bonne origine", filled == "ok" && values == "moi@void.test|selftest-1", "\(filled ?? "nil") \(values ?? "nil")")
        _ = await js(login, "document.getElementById('u').value = ''; document.getElementById('p').value = ''; return 1;")
        login.loginHost = "void-login-b.example"   // credentials of another site, e.g. a frame that navigated away
        let refused = await PasswordManager.shared.inject(account: "moi@void.test", password: "selftest-2", into: login)
        let after = await js(login, "return document.getElementById('p').value;") as? String
        check("Mots de passe : jamais écrits dans une autre origine", refused == "origin" && after == "", "\(refused ?? "nil") p=\"\(after ?? "nil")\"")

        // 7a'. Session file: tolerant decoding, damaged file set aside, backup used.
        testSessionStore()

        // 7c. Tab lifecycle: dialogs, crashes, pinned tabs.
        await testTabLifecycle(in: space)

        // 7d. Downloads and links to other apps.
        await testDownloads(in: space)

        // 7e. Address field: shows the page actually displayed, never a navigation in progress.
        await testAddressSpoofing(in: space)

        // 7f. History database: write-ahead log, no rewrite of an unchanged title, stable suggestions.
        let history = HistoryStore.shared
        check("Historique : journal WAL (écritures sans synchronisation complète)", history.journalMode == "wal", history.journalMode ?? "nil")
        let writes = history.titleWrites
        let probe = URL(string: "https://void-title.example/\(UUID().uuidString)")!   // no such row: nothing is modified
        for _ in 0..<10 { history.updateTitle(url: probe, title: "(3) Messages") }
        check("Historique : un titre inchangé n'est écrit qu'une fois", history.titleWrites - writes == 1, "\(history.titleWrites - writes) écriture(s)")
        let ids1 = SuggestionEngine.suggestions(for: "exa", browser: browser).map(\.id)
        let ids2 = SuggestionEngine.suggestions(for: "exa", browser: browser).map(\.id)
        check("Barre de commande : suggestions stables d'un calcul à l'autre", !ids1.isEmpty && ids1 == ids2 && Set(ids1).count == ids1.count)

        // 7b. Accent color: live, persisted, used by reader and picker
        let savedAccent = settings.accent
        settings.accent = .green
        check("Couleur : mémorisée", UserDefaults.standard.string(forKey: "accent") == "green")
        check("Couleur : palette centralisée (vert, thème clair)", Theme.accentCSS.light == "#12703A", Theme.accentCSS.light)

        // 8. UI snapshots
        settings.sidebarVisible = true
        settings.tabLayout = .sidebar
        settings.theme = .dark
        browser.select(a)
        await sleep(1.5)
        await snapshotWindow("sidebar-dark")
        settings.tabLayout = .top
        await sleep(1.5)
        await snapshotWindow("top-dark")
        settings.theme = .light
        await sleep(1.5)
        await snapshotWindow("top-light")
        settings.tabLayout = .sidebar
        await sleep(1.5)
        await snapshotWindow("sidebar-light")
        browser.showCommandBar(.currentTab)
        await sleep(1)
        await snapshotWindow("command-bar")
        browser.commandBar = nil

        // New tab settings, in the light theme with the green accent
        let savedBar = settings.showBookmarksBar, savedIcons = settings.tabIconStyle, savedWidth = settings.sidebarWidth
        settings.showBookmarksBar = true
        settings.tabIconStyle = .letters
        settings.sidebarWidth = 320
        _ = await js(a, "document.body.style.height = '6000px'; window.scrollTo(0, 2000); return 1;")
        await sleep(1.5)
        await snapshotWindow("tabs-settings-light-green")
        check("Barre de favoris + lettres + largeur : mémorisés", UserDefaults.standard.bool(forKey: "showBookmarksBar")
              && UserDefaults.standard.string(forKey: "tabIconStyle") == "letters" && UserDefaults.standard.double(forKey: "sidebarWidth") == 320)
        settings.theme = .dark
        for choice in AccentChoice.allCases {
            settings.accent = choice
            await sleep(0.6)
            await snapshotWindow("accent-\(choice.rawValue)-dark")
        }
        settings.sidebarAutoHide = true
        await sleep(1.2)
        await snapshotWindow("tabs-hidden")
        let buttonsHidden = browser.window?.standardWindowButton(.closeButton)?.isHidden == true
        check("Onglets masqués (⌘S) : la page occupe la fenêtre, boutons de fenêtre masqués", buttonsHidden)
        settings.sidebarAutoHide = false
        settings.accent = .pink
        let savedPanel = UserDefaults.standard.string(forKey: "settingsPanel")
        for (panel, theme) in [("tabs", ThemeChoice.dark), ("general", .light)] {
            UserDefaults.standard.set(panel, forKey: "settingsPanel")
            settings.theme = theme
            browser.openSettingsAction?()
            await sleep(1.5)
            if let settingsWindow = NSApp.windows.first(where: { $0.isVisible && $0 !== browser.window && $0.title != "Void" && !($0 is NSPanel) }) {
                await snapshotWindow("settings-\(panel)-pink-\(theme.rawValue)", window: settingsWindow)
                settingsWindow.performClose(nil)
                await sleep(0.5)
            }
        }
        UserDefaults.standard.set(savedPanel, forKey: "settingsPanel")
        settings.theme = .dark
        settings.showBookmarksBar = savedBar
        settings.tabIconStyle = savedIcons
        settings.sidebarWidth = savedWidth
        settings.accent = savedAccent

        // First-launch personalization
        check("Personnalisation : jamais affichée pendant l'auto-test", browser.onboardingStep == nil || settings.onboardingCompleted)
        let savedOnboarding = settings.onboardingCompleted
        settings.onboardingCompleted = false
        for step in 0..<OnboardingView.stepCount {
            browser.onboardingStep = step
            await sleep(0.9)
            await snapshotWindow("onboarding-\(step)")
        }
        settings.theme = .light
        browser.onboardingStep = 1
        await sleep(0.9)
        await snapshotWindow("onboarding-1-light")
        settings.theme = .dark
        browser.finishOnboarding()
        await sleep(0.5)
        check("Personnalisation : « Commencer » la ferme et la mémorise", browser.onboardingStep == nil && settings.onboardingCompleted
              && UserDefaults.standard.bool(forKey: "onboardingCompleted"))
        settings.onboardingCompleted = savedOnboarding

        let priv = BrowserWindows.shared.openPrivateWindow(url: URL(string: "https://example.com/?private-snapshot"))
        await sleep(3)
        await snapshotWindow("private-window-dark", window: priv.window, tab: priv.selectedTab)
        settings.theme = .light
        await sleep(1)
        await snapshotWindow("private-window-light", window: priv.window, tab: priv.selectedTab)
        settings.tabLayout = .top
        await sleep(1)
        await snapshotWindow("private-window-top", window: priv.window, tab: priv.selectedTab)
        priv.window?.performClose(nil)
        await sleep(0.5)

        // Reordering tabs by dragging them, with mouse events posted to the event queue
        await testTabDrag(in: space)

        // A Chrome extension (.crx) installed and run: content script, chrome.tabs
        await testExtensions(in: space)

        settings.tabLayout = savedLayout
        settings.theme = savedTheme
        settings.sidebarVisible = savedSidebar
        browser.deleteSpace(other)
        browser.deleteSpace(space)   // also removes its on-disk data store
        write()
    }

    /// Native mouse click (optionally with a move first) at the centre of an element.
    private func click(_ tab: Tab, selector: String, modifiers: NSEvent.ModifierFlags, move: Bool = false) async {
        guard let webView = tab.webView, let window = webView.window else {
            NSLog("[Void features] click %@ impossible : webView=%@ window=%@ superview=%@", selector, tab.webView == nil ? "nil" : "ok",
                  tab.webView?.window == nil ? "nil" : "ok", tab.webView?.superview.map { String(describing: type(of: $0)) } ?? "nil")
            return
        }
        guard let p = await webView.voidCall("const r = document.querySelector(s).getBoundingClientRect(); return {x: r.left + r.width/2, y: r.top + r.height/2};",
                                             arguments: ["s": selector]) as? [String: Double] else { return }
        let local = NSPoint(x: p["x"]!, y: webView.isFlipped ? p["y"]! : webView.bounds.height - p["y"]!)
        let location = webView.convert(local, to: nil)
        let hit = window.contentView?.superview?.hitTest(location)
        NSLog("[Void features] click %@ at %@ → %@ (key=%d)", selector, NSStringFromPoint(location), hit.map { String(describing: type(of: $0)) } ?? "nil", window.isKeyWindow ? 1 : 0)
        var types: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp]
        if move { types.insert(.mouseMoved, at: 0) }
        for type in types {
            if let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(e)
            }
            await sleep(type == .mouseMoved ? 0.4 : 0.08)
        }
    }

    // MARK: - Tab lifecycle

    private func testTabLifecycle(in space: Space) async {
        let page = "<!doctype html><body style='font:30px system-ui'>Void</body>"
        let front = await htmlTab(page, in: space, base: "https://void-front.example/")
        let back = await htmlTab(page, in: space, base: "https://void-back.example/")
        browser.select(front)
        await sleep(0.3)

        // A dialog from a tab that isn't shown must not block the app.
        let start = Date()
        let answer = await js(back, "const ok = confirm('?'); alert('x'); return ok === false ? 'dismissed' : 'shown';") as? String
        let elapsed = Date().timeIntervalSince(start)
        check("Dialogue d'un onglet en arrière-plan : ne bloque pas l'app", answer == "dismissed" && elapsed < 2,
              "\(answer ?? "nil") en \(String(format: "%.1f", elapsed)) s")

        // Crash of the page's process: background tab sleeps, shown tab reloads once, then stops.
        if let wv = back.webView, let delegate = wv.navigationDelegate as? TabWebDelegate {
            delegate.webViewWebContentProcessDidTerminate(wv)
            check("Plantage d'un onglet en arrière-plan : mis en veille, pas rechargé", back.isAsleep)
        }
        if let wv = front.webView, let delegate = wv.navigationDelegate as? TabWebDelegate {
            delegate.webViewWebContentProcessDidTerminate(wv)
            let firstError = front.loadError
            delegate.webViewWebContentProcessDidTerminate(wv)
            check("Plantages répétés de l'onglet affiché : un rechargement puis un message, pas de boucle",
                  firstError == nil && front.loadError != nil, front.loadError ?? "nil")
            front.loadError = nil
        }

        // A pinned tab whose first load turns into a download stays pinned.
        let pinnedFile = browser.openTab(url: nil, in: space)
        browser.togglePin(pinnedFile)
        if let wv = pinnedFile.webView, let delegate = wv.navigationDelegate as? TabWebDelegate {
            delegate.closeIfEmpty(wv)
            check("Onglet épinglé devenu téléchargement : jamais supprimé", space.pinned.contains { $0 === pinnedFile })
        }
        browser.close(pinnedFile, force: true)

        // ⌘W on a pinned tab in Picture in Picture: PiP is left, then the tab really sleeps.
        let pip = await htmlTab(page, in: space, base: "https://void-pip.example/")
        browser.togglePin(pip)
        browser.select(pip)
        pip.isInPiP = true
        browser.closeCurrentTab()
        await sleep(1.5)
        check("⌘W sur un épinglé en PiP : sort du PiP puis se met en veille",
              pip.isAsleep && !pip.isInPiP && space.pinned.contains { $0 === pip })
        browser.close(pip, force: true)
    }

    // MARK: - Downloads

    private func testDownloads(in space: Space) async {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("void-downloads-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        let savedFolder = settings.downloadFolderPath
        settings.downloadFolderPath = folder.path
        defer { settings.downloadFolderPath = savedFolder; try? fm.removeItem(at: folder) }

        let spoof = DownloadManager.sanitizedFilename("facture\u{202E}fdp.app")
        check("Téléchargement : caractères d'inversion retirés du nom", !spoof.unicodeScalars.contains { $0.value == 0x202E } && spoof == "facturefdp.app", spoof)
        let hidden = DownloadManager.sanitizedFilename("../.profile")
        check("Téléchargement : pas de fichier caché ni de chemin", !hidden.hasPrefix(".") && !hidden.contains("/"), hidden)
        let first = DownloadManager.uniqueDestination(for: "rapport.pdf", in: folder)
        let second = DownloadManager.uniqueDestination(for: "rapport.pdf", in: folder)
        check("Téléchargement : deux fichiers du même nom en même temps → deux chemins", first != second, second.lastPathComponent)
        DownloadManager.release(first); DownloadManager.release(second)

        // A real download through WebKit, into the temporary folder.
        let tab = await htmlTab("<!doctype html><body>dl</body>", in: space, base: "https://void-dl.example/")
        let source = URL(string: "data:application/octet-stream;base64,Vm9pZA==")!
        tab.webView?.startDownload(using: URLRequest(url: source)) { download in
            DownloadManager.shared.adopt(download, from: URL(string: "https://void-dl.example/fichier.bin"), in: tab.browser)
        }
        var item: DownloadItem?
        for _ in 0..<40 {
            await sleep(0.25)
            item = DownloadManager.shared.items.first { $0.sourceURL?.host() == "void-dl.example" }
            if item?.state == .finished { break }
        }
        let quarantined = item?.destination.flatMap { try? $0.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties } != nil
        check("Téléchargement : fichier en quarantaine (Gatekeeper le vérifiera)", item?.state == .finished && quarantined,
              "\(item?.destination?.lastPathComponent ?? "aucun fichier")")
        if let item { DownloadManager.shared.cancel(item); DownloadManager.shared.clearFinished() }

        // Links to other apps.
        check("Liens vers d'autres apps : smb:// refusé", ExternalURLPolicy.decide(scheme: "smb", userClick: true, fromMainFrame: true) == .refuse)
        check("Liens vers d'autres apps : refusés depuis un cadre intégré ou un script",
              ExternalURLPolicy.decide(scheme: "zoommtg", userClick: true, fromMainFrame: false) == .refuse
              && ExternalURLPolicy.decide(scheme: "mailto", userClick: false, fromMainFrame: true) == .refuse)
        check("Liens vers d'autres apps : mailto ouvert, les autres après confirmation",
              ExternalURLPolicy.decide(scheme: "mailto", userClick: true, fromMainFrame: true) == .open
              && ExternalURLPolicy.decide(scheme: "vscode", userClick: true, fromMainFrame: true) == .ask)
    }

    // MARK: - Address field

    private func testAddressSpoofing(in space: Space) async {
        // A local server that accepts connections and never answers: the navigation stays provisional.
        var held: [NWConnection] = []
        // A fixed port: WebKit refuses a number of "restricted" ports a random one could fall on.
        var listener: NWListener?
        var port: UInt16 = 0
        for candidate: UInt16 in [8765, 18765, 28765] {
            guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: candidate)!) else { continue }
            var ready = false
            l.stateUpdateHandler = { if case .ready = $0 { MainActor.assumeIsolated { ready = true } } }
            l.newConnectionHandler = { connection in
                connection.start(queue: .main)
                MainActor.assumeIsolated { held.append(connection) }
            }
            l.start(queue: .main)
            for _ in 0..<20 where !ready { await sleep(0.1) }
            if ready { listener = l; port = candidate; break }
            l.cancel()
        }
        defer { listener?.cancel(); held.forEach { $0.cancel() } }
        guard listener != nil else { check("Adresse : serveur de test", false); return }

        // WebKit blocks a public site from reaching the loopback address: the page itself is local too.
        let tab = await htmlTab("<!doctype html><body>page</body>", in: space, base: "http://localhost:\(port)/")
        _ = await js(tab, "history.pushState({}, '', '/suite'); return 1;")
        await sleep(0.3)
        check("Adresse : pushState suivi", tab.url?.path() == "/suite", tab.url?.absoluteString ?? "nil")

        // Straight to the web view (as a page-initiated navigation would), not through Tab.load.
        tab.webView?.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/banque")!))
        await sleep(1.5)
        let provisional = tab.webView?.url?.host() == "127.0.0.1"
        check("Adresse : une navigation qui n'aboutit pas n'est pas affichée", tab.addressText == "localhost",
              "affiché=\(tab.addressText) · WebKit expose l'URL en cours : \(provisional ? "oui" : "non") (\(tab.webView?.url?.absoluteString ?? "nil"), connexions=\(held.count), chargement=\(tab.isLoading), erreur=\(tab.loadError ?? "aucune"))")
        tab.webView?.stopLoading()

        tab.webView?.loadHTMLString("<!doctype html><body>autre</body>", baseURL: URL(string: "https://void-autre.example/"))
        await waitForLoad(tab)
        check("Adresse : une navigation aboutie est affichée", tab.addressText == "void-autre.example", tab.addressText)
    }

    // MARK: - Session file

    /// Works in a temporary folder: the user's session.json is never read or written.
    private func testSessionStore() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("void-session-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = StateStore.sessionDirectory
        StateStore.sessionDirectory = dir
        defer { StateStore.sessionDirectory = saved; try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.json")
        let space = UUID().uuidString, tab = UUID().uuidString

        // A newer version: unknown fields, a missing field, one damaged tab among good ones.
        let future = """
            {"version":2,"windows":[],"currentSpaceID":"\(space)","spaces":[{"id":"\(space)","name":"Perso","color":"red",
             "pinned":[{"id":"\(tab)","url":"https://example.com/","title":"Épinglé"}],
             "tabs":[{"id":"not-a-uuid-but-tab-kept","url":"https://a.example/"},{"id":42},{"url":"https://b.example/","title":"B","group":"x"}]}]}
            """
        try? Data(future.utf8).write(to: file)
        let s1 = StateStore.load()
        let sp = s1?.spaces.first
        check("Session : format plus récent relu (champs inconnus ou manquants)",
              sp?.id.uuidString == space && sp?.pinned.count == 1 && sp?.tabs.count == 3 && sp?.icon == "circle",
              "espaces=\(s1?.spaces.count ?? -1) épinglés=\(sp?.pinned.count ?? -1) onglets=\(sp?.tabs.count ?? -1)")

        // Truncated file (crash, full disk): set aside, the last good copy is used.
        try? Data(future.prefix(60).utf8).write(to: file)
        let s2 = StateStore.load()
        let corrupt = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("session.corrupt-") }
        check("Session : fichier abîmé mis de côté, copie de secours relue",
              s2?.spaces.first?.id.uuidString == space && corrupt.count == 1,
              "secours=\(s2 != nil) mis de côté=\(corrupt.count)")

        // Damaged and no backup: a fresh session, but the damaged file is still kept.
        try? fm.removeItem(at: dir.appendingPathComponent("session.backup.json"))
        try? Data("{".utf8).write(to: file)
        let s3 = StateStore.load()
        let kept = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("session.corrupt-") }.count
        check("Session : rien de lisible → session neuve, fichiers abîmés conservés", s3 == nil && kept == 2, "conservés=\(kept)")
    }

    // MARK: - Tab drag and drop

    /// The reordering itself, through `TabReorder` and the model, with the tabs at known places:
    /// a hidden or occluded window isn't drawn, so measuring the real views would depend on what
    /// the Mac is showing. The mouse gesture that feeds it is checked by hand.
    private func testTabDrag(in space: Space) async {
        while space.tabs.count < 4 { browser.openTab(url: nil, in: space, background: true) }
        func drag(_ tab: Tab, _ reorder: TabReorder, to translation: CGSize, steps: Int = 12) {
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                reorder.dragChanged(tab, translation: CGSize(width: translation.width * t, height: translation.height * t), browser: browser)
            }
        }

        // Sidebar: rows 34 pt high, 2 pt apart. The second row, dragged 76 pt down, passes the
        // middle of the next two and is drawn 4 pt below the slot it now has.
        let list = TabReorder(layout: .vertical, spacing: 2)
        for (i, tab) in space.tabs.enumerated() { list.record(CGRect(x: 0, y: CGFloat(i) * 36, width: 200, height: 34), for: tab.id) }
        let row = space.tabs[1]
        drag(row, list, to: CGSize(width: 0, height: 76))
        let rowIndex = space.tabs.firstIndex { $0 === row }
        check("Glisser-déposer (barre latérale) : l'onglet prend la place visée", rowIndex == 3, "position \(rowIndex.map(String.init) ?? "?") / 3")
        check("Glisser-déposer (barre latérale) : l'onglet suit le pointeur", list.offset == CGSize(width: 0, height: 4), "\(list.offset)")
        list.dragEnded()
        check("Glisser-déposer : relâché, l'onglet rejoint sa place", list.draggedID == nil && list.offset == .zero)

        // Top bar: a row of pills 4 pt apart, the active one wider (360 pt, the others 150). The
        // first pill, dragged 300 pt right, passes the middle of the wide one only, and stays on the row.
        let row2 = TabReorder(layout: .horizontal, spacing: 4)
        var x: CGFloat = 0
        for (i, tab) in space.tabs.enumerated() {
            let width: CGFloat = i == 1 ? 360 : 150
            row2.record(CGRect(x: x, y: 7, width: width, height: 30), for: tab.id)
            x += width + 4
        }
        let pill = space.tabs[0]
        drag(pill, row2, to: CGSize(width: 300, height: 9))
        let pillIndex = space.tabs.firstIndex { $0 === pill }
        check("Glisser-déposer (barre du haut) : l'onglet prend la place visée", pillIndex == 1, "position \(pillIndex.map(String.init) ?? "?") / 1")
        check("Glisser-déposer (barre du haut) : l'onglet suit le pointeur sur la ligne", row2.offset == CGSize(width: -64, height: 0), "\(row2.offset)")
        row2.dragEnded()

        // A press on a tab makes the window unmovable until the release (hover can't be simulated:
        // the pointer is put over a tab through the same entry point as SwiftUI's onHover).
        if let window = browser.window, let tab = space.tabs.first {
            TabDragWindowLock.pointer(isOver: tab.id, true)
            let location = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)   // on the page, where a click does nothing
            func post(_ type: NSEvent.EventType) {
                if let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            post(.leftMouseDown)
            await sleep(0.2)
            let lockedDuringPress = !window.isMovable
            post(.leftMouseUp)
            await sleep(0.2)
            TabDragWindowLock.pointer(isOver: tab.id, false)
            check("Glisser-déposer : la fenêtre ne peut pas être déplacée pendant qu'on tient un onglet", lockedDuringPress && window.isMovable)
        }

        // Pinned tiles: a grid of 4 columns; a pin takes the cell under its centre, among pins only.
        let pins = (0..<2).map { i -> Tab in
            let tab = browser.openTab(url: URL(string: "https://example.com/?pin\(i)"), in: space, background: true)
            browser.togglePin(tab)
            return tab
        }
        let grid = TabReorder(layout: .grid, spacing: 6)
        for (i, tab) in space.pinned.enumerated() { grid.record(CGRect(x: CGFloat(i) * 56, y: 0, width: 50, height: 40), for: tab.id) }
        drag(pins[0], grid, to: CGSize(width: 56, height: 4))
        grid.dragEnded()
        check("Glisser-déposer : les onglets épinglés se réordonnent entre eux", space.pinned.last === pins[0] && !space.tabs.contains { $0 === pins[0] })
        for pin in pins { browser.close(pin, force: true) }
    }

    // MARK: - Chrome extensions

    /// A Manifest V3 extension written like a Chrome one (`chrome.*`, service worker), packed as a
    /// .crx the way the Chrome Web Store serves it, installed and run on a page.
    private func testExtensions(in space: Space) async {
        let links = [
            "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh?hl=fr",
            "https://chrome.google.com/webstore/detail/ddkjiahejlhfcafbddmgiahcphecmpfh",
            "ddkjiahejlhfcafbddmgiahcphecmpfh",
        ]
        check("Extensions : identifiant tiré d'un lien du Chrome Web Store (nouveau et ancien format) ou saisi seul",
              links.allSatisfy { ChromeExtensions.extensionID(from: $0) == "ddkjiahejlhfcafbddmgiahcphecmpfh" }
              && ChromeExtensions.extensionID(from: "https://example.com/detail/ddkjiahejlhfcafbddmgiahcphecmpfh") == nil
              && ChromeExtensions.extensionID(from: "ddkjiahejlhfcafbddmgiahcphecmpfz") == nil)

        guard #available(macOS 15.4, *) else {
            check("Extensions : macOS 15.4 requis, test non exécuté", true)
            return
        }
        let settings = AppSettings.shared
        let wasEnabled = settings.extensionsEnabled
        let manager = ExtensionManager.shared
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("void-ext-\(UUID().uuidString)")
        let source = work.appendingPathComponent("src")
        defer { try? fm.removeItem(at: work) }
        try? fm.createDirectory(at: source, withIntermediateDirectories: true)
        let files = [
            "manifest.json": """
            {"manifest_version": 3, "name": "Void Self-Test", "version": "1.0", "description": "Auto-test de Void",
             "permissions": ["tabs", "storage"], "host_permissions": ["<all_urls>"],
             "background": {"service_worker": "background.js"},
             "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_idle"}],
             "action": {"default_title": "Void Self-Test"}, "options_page": "options.html"}
            """,
            "background.js": """
            chrome.runtime.onMessage.addListener((message, sender, reply) => {
              if (message.kind === "tabs") {
                chrome.tabs.query({}, (all) => chrome.tabs.query({active: true, currentWindow: true}, (active) =>
                  reply({count: all.length, active: active[0] && active[0].url, sender: sender.tab && sender.tab.url})));
              } else if (message.kind === "create") {
                chrome.tabs.create({url: message.url, active: false}, (tab) => reply({id: tab && tab.id}));
              }
              return true;
            });
            """,
            "options.html": "<!doctype html><title>Options</title><script src=options.js></script>",
            "options.js": "chrome.tabs.query({}, (tabs) => { document.title = 'options:' + tabs.length; });",
            "content.js": """
            document.documentElement.dataset.voidExt = "content";
            if (location.pathname === "/void-ext") chrome.runtime.sendMessage({kind: "tabs"}, (reply) => {
              document.documentElement.dataset.voidTabs = JSON.stringify(reply || {error: String(chrome.runtime.lastError && chrome.runtime.lastError.message)});
              chrome.runtime.sendMessage({kind: "create", url: location.origin + "/?from-extension"}, () => {});
            });
            """,
        ]
        for (name, text) in files { try? text.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        // zip → CRX3: "Cr24", version 3, header size, header (a stand-in: Void doesn't read it), zip.
        let zip = work.appendingPathComponent("ext.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, zip.path]
        try? ditto.run()
        ditto.waitUntilExit()
        func le32(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]) }
        let header = Data(repeating: 0x2a, count: 64)
        let crx = work.appendingPathComponent("void-self-test.crx")
        var crxData = Data("Cr24".utf8) + le32(3) + le32(header.count) + header
        crxData.append((try? Data(contentsOf: zip)) ?? Data())
        try? crxData.write(to: crx)
        check("Extensions : l'archive d'un .crx (CRX3) est retrouvée", (try? ChromeExtensions.zipData(fromCRX: crxData)) == (try? Data(contentsOf: zip)))

        await manager.install(from: crx)
        let context = manager.contexts.first { $0.webExtension.displayName == "Void Self-Test" }
        check("Extensions : un .crx s'installe (copie dans le dossier de Void), les extensions s'activent",
              context != nil && settings.extensionsEnabled && manager.record(for: context!)?.path.hasPrefix(ExtensionManager.folder.path) == true,
              manager.lastError ?? "")
        guard let context else { settings.extensionsEnabled = wasEnabled; return }

        let other = browser.openTab(url: URL(string: "https://example.com/?other-tab"), in: space, background: true)
        let page = await htmlTab("<!doctype html><title>Extensions</title><body>Page</body>", in: space, base: "https://example.com/void-ext")
        var tabsReply: [String: Any]?
        var injected = false
        for _ in 0..<40 {
            let state = await js(page, "return [document.documentElement.dataset.voidExt || '', document.documentElement.dataset.voidTabs || ''];") as? [String]
            injected = state?.first == "content"
            if let json = state?.last, !json.isEmpty {
                tabsReply = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                break
            }
            await sleep(0.25)
        }
        let errors = context.errors.map(\.localizedDescription).joined(separator: " · ")
        check("Extensions : le script de contenu s'exécute dans la page", injected, errors)
        check("Extensions : manifeste Chrome accepté sans erreur", context.errors.isEmpty, errors)
        // Counted without the tab the extension opens right after answering.
        let visible = BrowserWindows.shared.all.filter { !$0.isPrivate }.flatMap(\.extensionTabs)
            .filter { $0.url?.absoluteString.contains("from-extension") != true }.count
        check("Extensions : chrome.tabs.query voit les onglets de Void et l'onglet actif",
              tabsReply?["count"] as? Int == visible && (tabsReply?["active"] as? String)?.contains("example.com/void-ext") == true
              && (tabsReply?["sender"] as? String)?.contains("example.com/void-ext") == true,
              (tabsReply.map { "\($0)" } ?? "pas de réponse — \(errors)") + " · onglets Void : \(visible)")
        var created: [Tab] = []
        for _ in 0..<20 where created.isEmpty {
            created = browser.allTabs.filter { $0.url?.absoluteString.contains("from-extension") == true }
            await sleep(0.25)
        }
        await sleep(1)
        created = browser.allTabs.filter { $0.url?.absoluteString.contains("from-extension") == true }
        check("Extensions : chrome.tabs.create ouvre un onglet Void", created.count == 1 && created.first?.space === space, "\(created.count) onglet(s)")
        for tab in created { browser.close(tab, force: true) }
        browser.close(page, force: true)
        browser.close(other, force: true)

        // Captures: the extensions button, and the install button on a store page (not fetched:
        // a local page under the store's address).
        let savedLayout = settings.tabLayout
        let store = await htmlTab("<!doctype html><title>Void Self-Test — Chrome Web Store</title><body>Store</body>", in: space,
                                  base: "https://chromewebstore.google.com/detail/void-self-test/ddkjiahejlhfcafbddmgiahcphecmpfh")
        for _ in 0..<20 where browser.window == nil { await sleep(0.25) }   // run alone, the window may still be opening
        browser.window?.makeKeyAndOrderFront(nil)
        for layout in [TabLayout.sidebar, .top] {
            settings.tabLayout = layout
            await sleep(1)
            await snapshotWindow("extensions-\(layout.rawValue)", tab: store)
        }
        settings.tabLayout = savedLayout
        browser.close(store, force: true)

        // The options page: an extension page, in a tab, with the extension's APIs.
        manager.openOptions(context)
        var optionsTitle = ""
        for _ in 0..<40 where !optionsTitle.hasPrefix("options:") {
            await sleep(0.25)
            optionsTitle = BrowserWindows.shared.normalTarget.selectedTab?.title ?? ""
        }
        let optionsTab = BrowserWindows.shared.normalTarget.selectedTab
        check("Extensions : la page d'options s'ouvre dans un onglet et accède à chrome.tabs",
              optionsTab?.url?.scheme == "webkit-extension" && optionsTitle.hasPrefix("options:"), "« \(optionsTitle) » \(optionsTab?.url?.absoluteString ?? "")")
        if let optionsTab, optionsTab.url?.scheme == "webkit-extension" { optionsTab.browser?.close(optionsTab, force: true) }

        let folder = manager.record(for: context)?.path
        manager.uninstall(context)
        check("Extensions : désinstallée, sa copie est supprimée", !manager.contexts.contains { $0 === context }
              && folder.map { !fm.fileExists(atPath: $0) } == true)
        settings.extensionsEnabled = wasEnabled
    }

    // MARK: - Windows, sleep

    /// Opens a private window, checks it, closes it; returns weak references to what must be gone.
    private final class WeakRefs {
        weak var model: BrowserModel?
        weak var store: WKWebsiteDataStore?
    }

    private func privateWindowChecks(normalTab: Tab) async -> WeakRefs {
        let windows = BrowserWindows.shared
        let reference = browser.window?.frame.size
        let model = windows.openPrivateWindow()
        await sleep(1.5)
        check("⌘⇧N : fenêtre privée ouverte et active", model.window?.isVisible == true && windows.active === model && model.isPrivate)
        check("Nouvelle fenêtre : même taille que la fenêtre d'origine, stable", model.window?.frame.size == reference,
              "\(model.window.map { NSStringFromSize($0.frame.size) } ?? "-") vs \(reference.map(NSStringFromSize) ?? "-")")
        let p1 = model.openTab(url: URL(string: "https://example.com/?private=1"))
        await waitForLoad(p1)
        let store = p1.webView?.configuration.websiteDataStore
        check("⌘T dans une fenêtre privée : onglet privé, stockage éphémère", p1.isPrivate && store?.isPersistent == false)
        _ = await js(p1, "document.cookie = 'voidprivate=1; max-age=600; path=/'; return 1;")
        let links = await htmlTab("<!doctype html><body>Lien</body>", in: model.currentSpace, base: "https://example.com/")
        // A page-opened window (target=_blank, window.open): Void's JS calls carry a user gesture,
        // so this doesn't depend on the test window having the focus.
        _ = await js(links, "window.open('https://example.com/?private=link'); return 1;")
        await sleep(2)
        let viaLink = model.currentSpace.tabs.first { $0.url?.absoluteString.contains("private=link") == true }
        await waitForLoad(viaLink ?? links)
        let linkCookie = await js(viaLink ?? links, "return document.cookie;") as? String ?? ""
        check("Lien ouvert depuis une fenêtre privée : onglet privé, même stockage", viaLink?.isPrivate == true
              && viaLink?.webView?.configuration.websiteDataStore === store && linkCookie.contains("voidprivate=1"), "cookie=\"\(linkCookie)\"")
        let normalCookie = await js(normalTab, "return document.cookie;") as? String ?? ""
        check("Fenêtre privée isolée des fenêtres normales", !normalCookie.contains("voidprivate"), "normal=\"\(normalCookie)\"")
        check("Fenêtre privée : aucune suggestion d'historique", SuggestionEngine.suggestions(for: "", browser: model).isEmpty
              && !SuggestionEngine.suggestions(for: "example", browser: model).contains { $0.symbol == "clock" })
        model.togglePin(p1)
        check("Fenêtre privée : épinglage et espaces désactivés", !p1.isPinned && !model.managesSpaces && model.spaces.count == 1)
        check("Fenêtre privée : jamais sauvegardée", model.isEphemeralSession)
        model.window?.performClose(nil)
        await sleep(1)
        check("Fermeture : onglets détruits, fenêtre retirée", p1.isAsleep && model.allTabs.isEmpty && !windows.all.contains { $0 === model })
        let refs = WeakRefs()
        refs.model = model
        refs.store = store
        return refs
    }

    private func secondaryWindowChecks(space: Space) async {
        let windows = BrowserWindows.shared
        windows.openNormalWindow()
        await sleep(1)
        let model = windows.active
        check("⌘N : nouvelle fenêtre normale (historique actif, session non écrasée)", model !== browser && !model.isPrivate
              && model.window?.isVisible == true && model.isEphemeralSession == browser.isEphemeralSession && model.kind == .secondary)
        let mirror = model.spaces.first { $0.id == space.id }
        if let mirror {
            let tab = model.openTab(url: URL(string: "https://example.com/?secondary"), in: mirror)
            await waitForLoad(tab)
            let cookie = await js(tab, "return document.cookie;") as? String ?? ""
            check("⌘N : mêmes espaces, même stockage (cookie de l'espace visible)", cookie.contains("voidtest=spaceA") && tab.webView?.configuration.websiteDataStore.isPersistent == true, "cookie=\"\(cookie)\"")
        } else {
            check("⌘N : mêmes espaces, même stockage (cookie de l'espace visible)", false, "espace absent")
        }
        model.window?.performClose(nil)
        await sleep(0.5)
    }

    private func tabSleepChecks(space: Space, pinned: Tab, other: Tab) async {
        let long = browser.openTab(url: URL(string: "https://example.com/?history"), in: space)
        await waitForLoad(long)
        long.load(URL(string: "https://fr.wikipedia.org/wiki/Trou_noir")!)
        await waitForLoad(long, timeout: 25)
        _ = await js(long, "window.scrollTo(0, 2400); return 1;")
        await sleep(1)
        let expected = await js(long, "const r = document.scrollingElement; return window.scrollY / (r.scrollHeight - window.innerHeight);") as? Double ?? -1
        check("Progression de lecture : l'onglet actif se remplit au défilement", long.readingProgress > 0 && abs(long.readingProgress - expected) < 0.005,
              String(format: "onglet %.4f, page %.4f", long.readingProgress, expected))
        await snapshotWindow("reading-progress")

        browser.select(other)
        long.lastAccess = Date().addingTimeInterval(-31 * 60)
        pinned.lastAccess = Date().addingTimeInterval(-31 * 60)
        let typed = await htmlTab("<!doctype html><body><input id=f style='font:30px system-ui;margin:40px'></body>", in: space)
        await click(typed, selector: "#f", modifiers: [])
        _ = await js(typed, "document.getElementById('f').focus(); return 1;")
        if let window = typed.webView?.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                           windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) {
            window.sendEvent(e)
        }
        await sleep(0.8)
        if !typed.hasUserInput, let webView = typed.webView {
            // Key events are dropped when the test window isn't key: type through the text input path.
            webView.window?.makeFirstResponder(webView)
            webView.insertText("a")
            await sleep(0.8)
        }
        browser.select(other)
        typed.lastAccess = Date().addingTimeInterval(-31 * 60)
        browser.sleepInactiveTabs()
        await sleep(1)
        check("Veille après 30 min d'inactivité", long.isAsleep)
        check("Veille : l'onglet où du texte a été saisi reste éveillé", !typed.isAsleep && typed.hasUserInput)
        check("Veille : l'onglet épinglé reste éveillé", !pinned.isAsleep)
        check("Veille : l'onglet affiché reste éveillé", !other.isAsleep)
        let remembered = long.pendingScroll
        browser.select(long)
        await waitForLoad(long, timeout: 25)
        var y: Double = -1
        for _ in 0..<20 {   // the scroll position is restored once the page has loaded
            y = await js(long, "return window.scrollY;") as? Double ?? -1
            if abs(y - 2400) < 80 { break }
            await sleep(0.5)
        }
        let height = await js(long, "return document.scrollingElement.scrollHeight;") as? Double ?? -1
        check("Réveil : même page, historique Précédent conservé", long.webView?.url?.absoluteString.contains("Trou_noir") == true && long.canGoBack,
              "précédent=\(long.canGoBack)")
        check("Réveil : revient à l'endroit où on l'a laissé", abs(y - 2400) < 80,
              "scrollY=\(Int(y)) mémorisé=\(remembered.map { "\(Int($0.y))" } ?? "nil") url=\(long.webView?.url?.absoluteString ?? "nil") hauteur=\(Int(height))")
        browser.close(typed, force: true)
    }

    /// Chrome (SwiftUI) + page, composited from the window's views.
    private func snapshotWindow(_ name: String, window: NSWindow? = nil, tab: Tab? = nil) async {
        guard let window = window ?? browser.window, let content = window.contentView else { return }
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        // cacheDisplay doesn't capture WKWebView's remote layers: draw a real snapshot on top.
        let shown = tab ?? (window === browser.window ? browser.selectedTab : nil)
        // Overlays above the page (command bar, onboarding) would be covered by the page snapshot.
        if browser.commandBar == nil, browser.onboardingStep == nil, let webView = shown?.webView, webView.window === window {
            let shot: NSImage? = await withCheckedContinuation { c in webView.takeSnapshot(with: nil) { img, _ in c.resume(returning: img) } }
            if let shot {
                let frame = webView.convert(webView.bounds, to: content)
                let flipped = NSRect(x: frame.minX, y: content.isFlipped ? content.bounds.height - frame.maxY : frame.minY, width: frame.width, height: frame.height)
                image.lockFocus()
                shot.draw(in: flipped)
                image.unlockFocus()
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: (outputPath as NSString).deletingPathExtension + "-\(name).png"))
    }

    private func write() {
        let md = "# Void — auto-test des fonctionnalités\n\n- Date : \(ISO8601DateFormatter().string(from: Date()))\n- Résultat : \(passed) ✅ / \(failed) ❌\n\n" + lines.joined(separator: "\n") + "\n"
        try? md.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
}
#endif
