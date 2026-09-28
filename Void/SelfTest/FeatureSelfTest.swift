#if DEBUG
import AppKit
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

    func run() async {
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
