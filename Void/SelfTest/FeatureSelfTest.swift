#if DEBUG
import AppKit
import Network
import SwiftUI
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

    /// The traffic lights share the centre line of the first row of buttons, also after a resize.
    private func testTrafficLights() async {
        let settings = AppSettings.shared
        guard let window = browser.window else {
            check("Feux de fenêtre : fenêtre introuvable", false)
            return
        }
        let saved = (settings.tabLayout, settings.sidebarVisible, settings.sidebarAutoHide)
        settings.sidebarVisible = true
        settings.sidebarAutoHide = false
        // Each button's centre, read again every time: AppKit may swap a button for a new one.
        func centres() -> [CGFloat] {
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { kind in
                guard let b = window.standardWindowButton(kind) else { return -1 }
                return window.frame.height - b.convert(b.bounds, to: nil).midY
            }
        }
        for (layout, expected) in [(TabLayout.top, CGFloat(22)), (.sidebar, 19)] {
            settings.tabLayout = layout
            await sleep(0.8)
            let before = centres()
            let frame = window.frame
            window.setFrame(frame.insetBy(dx: 20, dy: 20), display: true)
            await sleep(0.5)
            let resized = centres()
            window.setFrame(frame, display: true)
            // Another window in front, then back: the title bar is drawn again inactive, then active.
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.makeKeyAndOrderFront(nil)
            await sleep(0.5)
            let inactive = centres()
            other.close()
            window.makeKeyAndOrderFront(nil)
            await sleep(0.5)
            let active = centres()
            let all = before + resized + inactive + active
            check("Feux de fenêtre (les trois) alignés sur les boutons (\(layout.rawValue) ; redimensionnée, inactive, active)",
                  all.allSatisfy { abs($0 - expected) < 0.5 },
                  "rouge/jaune/vert \(before) · redim. \(resized) · inactive \(inactive) · active \(active), attendu \(expected)")
        }
        // Full screen: the traffic lights are gone, the bar starts at the window's edge (capture).
        // Twice, in both layouts: leaving full screen used to end the app (layout exception).
        for layout in [TabLayout.sidebar, .top] {
            settings.tabLayout = layout
            window.toggleFullScreen(nil)
            _ = await until(5) { window.styleMask.contains(.fullScreen) }
            await sleep(1.5)
            window.toggleFullScreen(nil)
            _ = await until(5) { !window.styleMask.contains(.fullScreen) }
            await sleep(1.5)
        }
        window.toggleFullScreen(nil)
        let entered = await until(5) { window.styleMask.contains(.fullScreen) }
        await sleep(1.5)
        let inFullScreen = browser.isFullScreen
        await snapshotWindow("plein-ecran-barre-du-haut")
        window.toggleFullScreen(nil)
        let exited = await until(5) { !window.styleMask.contains(.fullScreen) }
        await sleep(1.5)
        check("Plein écran : la place des feux est rendue à la barre, puis reprise en sortant",
              entered && inFullScreen && exited && !browser.isFullScreen,
              "entré \(entered) · suivi \(inFullScreen) · sorti \(exited) · après \(browser.isFullScreen)")
        (settings.tabLayout, settings.sidebarVisible, settings.sidebarAutoHide) = saved
    }

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
        "stabilite": { t, space in await t.testStability(in: space) },
        "glisser": { t, space in await t.testTabDrag(in: space) },
        "disposition": { t, space in await t.testLayoutSwitch(in: space) },
        "extensions": { t, space in await t.testExtensions(in: space) },
        "lancement-extensions": { t, _ in await t.testInstalledExtensionsLoad() },
        "popups-installes": { t, space in await t.testInstalledPopups(in: space) },
        "store": { t, space in await t.testWebStorePage(in: space) },
        "plein-ecran": { t, space in await t.testElementFullscreen(in: space) },
        "barre-commande": { t, space in await t.snapshotCommandBar(in: space) },
        "lecteurs": { t, space in await t.testPlayers(in: space) },
        "mots-de-passe": { t, space in await t.testPasswords(in: space) },
        "historique": { t, _ in t.testHistoryRetention() },
        "proton-champ": { t, space in await t.testExtensionInlineAutofill(in: space) },
        "corrections": { t, space in await t.testReportFixes(in: space) },
        "feux": { t, _ in await t.testTrafficLights() },
        "notes": { t, space in await t.testVoidNotes(in: space) },
        "nouvel-onglet": { t, space in await t.testNewTabLinks(in: space) },
        "page-nouvel-onglet": { t, space in await t.testNewTabPage(in: space) },
        "conversion": { t, _ in await t.testConversions() },
        "reveil-extensions": { t, space in await t.testExtensionBackgroundWake(in: space) },
        "visio": { t, space in await t.testMeetings(in: space) },
        "fermer-autres": { t, space in await t.testCloseOtherTabs(in: space) },
    ]

    /// Context menu → "Fermer les autres onglets": the tab stays, shown, with the pinned tabs.
    private func testCloseOtherTabs(in space: Space) async {
        let tabs = (0..<4).map { browser.openTab(url: URL(string: "https://example.com/?n=\($0)"), in: space, background: true) }
        let pinned = browser.openTab(url: URL(string: "https://example.com/?pin"), in: space, background: true)
        browser.togglePin(pinned)
        browser.closeOtherTabs(than: tabs[2])
        check("Fermer les autres onglets : seul l'onglet choisi reste, sélectionné, l'épinglé aussi",
              space.tabs.count == 1 && space.tabs.first === tabs[2] && browser.selectedTab === tabs[2] && space.pinned.contains { $0 === pinned },
              "onglets \(space.tabs.count) · épinglés \(space.pinned.count)")
        browser.reopenClosedTab()
        check("Fermer les autres onglets : ⌘⇧T en rouvre un", space.tabs.count == 2, "\(space.tabs.count)")
    }

    /// A video call asks for the camera and the micro: the page gets an answer (refused in
    /// self-test, the camera is never opened) instead of waiting forever. Optionally, real
    /// sites: -VoidDiagURLs https://meet.jit.si/…,… (text and capture of each, in the report).
    private func testMeetings(in space: Space) async {
        browser.window?.makeKeyAndOrderFront(nil)
        let tab = await htmlTab("<!doctype html><body>visio</body>", in: space, base: "https://void-visio.example/")
        browser.select(tab)
        // In the page's own world, as a site would.
        let outcome = try? await tab.webView?.callAsyncJavaScript("""
            try { await navigator.mediaDevices.getUserMedia({video: true, audio: true}); return 'accordé'; }
            catch (e) { return e.name; }
            """, contentWorld: .page) as? String
        check("Visio : la demande caméra + micro reçoit une réponse", outcome == "NotAllowedError", outcome ?? "aucune réponse en 5 s")

        let urls = UserDefaults.standard.string(forKey: "VoidDiagURLs")?.split(separator: ",") ?? []
        for (i, u) in urls.enumerated() {
            let site = browser.openTab(url: URL(string: String(u)), in: space)
            await sleep(15)
            let info = await js(site, "return location.href + ' · ' + (document.body ? document.body.innerText : '').slice(0, 400);") as? String
            check("Visio : \(u)", info != nil, info ?? "nil")
            await snapshotWindow("visio-\(i)", tab: site)
        }
    }

    /// Extensions keep working long after launch: WebKit unloads an idle background after 30 s and
    /// wakes it up when needed. A woken worker isn't taken for a lost one (reloading the extension
    /// would cut it off from every open page), and its button still opens its popup.
    /// Meant for a copy of a real profile (Proton Pass).
    private func testExtensionBackgroundWake(in space: Space) async {
        guard #available(macOS 15.4, *) else { return }
        let manager = ExtensionManager.shared
        for _ in 0..<40 where manager.contexts.count < manager.installedRecords.count { await sleep(0.25) }
        for _ in 0..<20 where browser.window == nil { await sleep(0.25) }
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard !manager.contexts.isEmpty else { check("Réveil des extensions : aucune extension installée, test non exécuté", true); return }
        func name(_ context: WKWebExtensionContext) -> String { String((context.webExtension.displayName ?? context.uniqueIdentifier).prefix(24)) }

        await sleep(26)   // past the launch checks (ExtensionManager.watchBackground)
        var answers: [String] = []
        for context in manager.contexts {
            let start = Date()
            answers.append("\(name(context)) : \(await manager.backgroundAnswers(context) ? "répond" : "muet") en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
        check("Réveil des extensions : l'arrière-plan répond après le lancement", !answers.contains { $0.contains("muet") },
              answers.joined(separator: " · ") + " · rechargements : \(manager.revivals)")

        let unloaded = await until(240) { !manager.contexts.contains(where: manager.backgroundIsLoaded) }
        check("Réveil des extensions : WebKit décharge les arrière-plans inactifs", unloaded,
              manager.contexts.filter(manager.backgroundIsLoaded).map(name).joined(separator: ", "))
        await sleep(2)

        // A login page: content scripts wake their background up.
        let revivals = manager.revivals
        let tab = await htmlTab("""
            <!doctype html><title>Connexion</title><body style="font:16px system-ui;padding:40px"><main><h1>Mon compte</h1>
            <form method="post" action="/login"><label>Courriel<br><input id="u" name="username" type="text" autocomplete="username" style="width:400px;height:36px"></label><br><br>
            <label>Mot de passe<br><input id="p" name="password" type="password" style="width:400px;height:36px"></label><br><br>
            <button type="submit">Me connecter</button></form></main></body>
            """, in: space, base: "https://login.urssaf.fr/")
        browser.select(tab)
        await sleep(5)
        let elements = (await js(tab, "return [...document.querySelectorAll('*')].filter(e => e.tagName.includes('-')).map(e => e.tagName.toLowerCase()).join(',');") as? String) ?? ""
        for context in manager.contexts {
            let start = Date()
            let answered = await manager.backgroundAnswers(context)
            let delay = Int(Date().timeIntervalSince(start) * 1000)
            manager.performAction(context, in: browser)
            await sleep(4)
            let popover = manager.shownPopover
            let text = try? await manager.shownPopupWebView?.evaluateJavaScript("document.body ? document.body.innerText.length : -1")
            check("Réveil des extensions : « \(name(context)) » répond après un réveil, son bouton ouvre son popup sans la recharger",
                  answered && manager.revivals == revivals && popover?.isShown == true && ((text as? Int) ?? 0) > 0,
                  "réponse=\(answered) en \(delay) ms · rechargements \(revivals) → \(manager.revivals) · popup affiché=\(popover?.isShown ?? false) texte=\(text.map { "\($0)" } ?? "nil") · page : \(elements)")
            popover?.performClose(nil)
            await sleep(1.5)
        }
        browser.close(tab)
    }

    /// Conversions answered in the address bar: units, currencies (rates given here, no network),
    /// and what must stay a plain search.
    private func testConversions() async {
        let rates = CurrencyRates(fileURL: nil)
        func value(_ input: String) -> String {
            switch QuickConverter.answer(for: input, rates: rates) {
            case .result(let result): result.text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
            case .loading: "chargement"
            case nil: "nil"
            }
        }
        let decimal = Locale.current.decimalSeparator ?? ","
        func expect(_ input: String, _ expected: String) -> String? {
            let got = value(input)
            return got == expected.replacingOccurrences(of: ",", with: decimal) ? nil : "« \(input) » → \(got)"
        }
        let units = [
            expect("10 km en miles", "10 km = 6,21371 mi"), expect("10km to mi", "10 km = 6,21371 mi"),
            expect("72 °F en °C", "72 °F = 22,22 °C"), expect("100 c en f", "100 °C = 212 °F"),
            expect("1,5 kg en lb", "1,5 kg = 3,30693 lb"), expect("2.5 l -> cl", "2,5 l = 250 cl"),
            expect("90 km/h en mph", "90 km/h = 55,9234 mph"), expect("3 h en min", "3 h = 180 min"),
            expect("12 in en cm", "12 in = 30,48 cm"), expect("5 go en mo", "5 Go = 5 000 Mo"),
            expect("2 To to Go", "2 To = 2 000 Go"), expect("1 ha = m2", "1 ha = 10 000 m²"),
        ].compactMap { $0 }
        check("Conversion : unités (longueur, température, masse, volume, vitesse, durée, données, surface)", units.isEmpty, units.joined(separator: " · "))

        let plain = ["10 km", "trou noir", "10 km en litres", "3 petits cochons", "2024 élections en france", "apple.com", "192.168.1.1", "10"]
            .filter { value($0) != "nil" }
        check("Conversion : une recherche ordinaire n'en est pas une", plain.isEmpty, plain.joined(separator: " · "))

        check("Conversion : devise sans taux, en attente", value("100 usd en eur") == "chargement", value("100 usd en eur"))
        rates.set(rates: ["USD": 1.25, "GBP": 0.8, "JPY": 160, "CHF": 0.95], day: "2026-10-01")
        let local = rates.localCurrency
        let money = [
            expect("100 usd en eur", "100 USD = 80 EUR"), expect("100 € en $", "100 EUR = 125 USD"),
            expect("$50 to gbp", "50 USD = 32 GBP"), expect("1 234,50 eur en yens", "1 234,5 EUR = 197 520 JPY"),
            expect("10 livres sterling en francs suisses", "10 GBP = 11,88 CHF"), expect("100 usd gbp", "100 USD = 64 GBP"),
            local == "EUR" ? expect("100 dollars", "100 USD = 80 EUR") : nil,
        ].compactMap { $0 }
        check("Conversion : devises (codes, symboles, noms), taux de la BCE", money.isEmpty && rates.sourceNote == "Taux BCE du 1 oct. 2026",
              money.joined(separator: " · ") + " " + (rates.sourceNote ?? "nil"))
        check("Conversion : devise inconnue ou identique → recherche", value("100 usd en xyz") == "nil" && value("100 eur en euros") == "nil",
              value("100 usd en xyz") + " " + value("100 eur en euros"))

        let parsed = CurrencyRates.parse("<Cube><Cube time='2026-10-01'><Cube currency='USD' rate='1.1298'/><Cube currency='JPY' rate='178.49'/><Cube currency='GBP' rate='0.85373'/><Cube currency='CHF' rate='0.9437'/><Cube currency='CAD' rate='1.5'/></Cube></Cube>")
        check("Conversion : fichier de la BCE lu", parsed?.day == "2026-10-01" && parsed?.rates["USD"] == 1.1298 && parsed?.rates.count == 5)

        // The real file, from the ECB (network).
        let live = CurrencyRates(fileURL: nil)
        let fetched = await live.fetch()
        check("Conversion : taux du jour récupérés auprès de la BCE", fetched && (live.rate("USD") ?? 0) > 0.5 && live.rate("EUR") == 1,
              "USD=\(live.rate("USD").map { "\($0)" } ?? "nil") · \(live.sourceNote ?? "nil")")

        let rows = SuggestionEngine.suggestions(for: "10 km en miles", browser: browser)
        let row = rows.firstIndex { if case .copy = $0.kind { true } else { false } }
        check("Conversion : affichée dans la barre d'adresse, sous la recherche (↩ recherche toujours)",
              row == 1 && rows.first?.symbol == "magnifyingglass" && rows[1].title.hasPrefix("10 km = 6"), rows.map(\.title).joined(separator: " | "))
    }

    /// ⌘T shows the new-tab page over the current tab, its field focused (no floating bar). What is
    /// typed there opens in a new tab; Esc, ⌘W or another space bring the tab back.
    private func testNewTabPage(in space: Space) async {
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let tab = await htmlTab("<!doctype html><body style='font:40px system-ui'>page sous la page nouvel onglet</body>", in: space)
        browser.select(tab)
        await sleep(0.3)
        guard let window = browser.window else { check("Page nouvel onglet : pas de fenêtre", false); return }
        var field: NSTextView? { window.firstResponder as? NSTextView }
        func press(_ code: UInt16, _ chars: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) {
                    window.sendEvent(e)
                }
            }
        }

        browser.showCommandBar(.newTab)
        let focused = await until { field != nil }
        check("Page nouvel onglet : ⌘T l'affiche, champ prêt, sans barre flottante",
              browser.selectedTab == nil && browser.commandBar == nil && browser.tabBeforeNewTabPage === tab && focused && !tab.isClosed,
              "premier répondeur : \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "aucun")")
        await snapshotWindow("nouvel-onglet")

        field?.insertText("10 km en miles", replacementRange: NSRange(location: NSNotFound, length: 0))
        await sleep(0.8)
        await snapshotWindow("nouvel-onglet-suggestions")
        press(53, "\u{1b}")
        let cleared = await until(2) { field?.string.isEmpty == true }
        press(53, "\u{1b}")
        let back = await until(2) { browser.selectedTab === tab }
        check("Page nouvel onglet : Échap efface la saisie, puis ramène l'onglet", cleared && back,
              "effacé : \(cleared), onglet : \(browser.selectedTab?.displayTitle ?? "aucun")")

        browser.showCommandBar(.newTab)
        _ = await until { field != nil }
        if NSApp.keyWindow === window { browser.closeTabOrWindow() } else { browser.leaveNewTabPage() }
        await sleep(0.3)
        check("Page nouvel onglet : ⌘W la quitte sans fermer d'onglet ni la fenêtre",
              browser.selectedTab === tab && !tab.isClosed && window.isVisible)

        let before = space.tabs
        browser.showCommandBar(.newTab)
        _ = await until { field != nil }
        field?.insertText("https://example.com/?via=newtabpage", replacementRange: NSRange(location: NSNotFound, length: 0))
        await sleep(0.5)
        press(36, "\r")
        let opened = await until(6) { browser.selectedTab?.url?.absoluteString.contains("via=newtabpage") == true }
        let new = space.tabs.filter { t in !before.contains { $0 === t } }
        check("Page nouvel onglet : ↩ ouvre la saisie dans un nouvel onglet, l'onglet d'avant reste",
              opened && new.count == 1 && !tab.isClosed && browser.tabBeforeNewTabPage == nil,
              new.map { $0.url?.absoluteString ?? "vide" }.joined(separator: ", "))
        new.forEach { browser.close($0, force: true) }

        if browser.managesSpaces {
            browser.select(tab)
            browser.showCommandBar(.newTab)
            let other = browser.addSpace(name: "Autre", icon: "circle")
            browser.switchSpace(to: space)
            check("Page nouvel onglet : changer d'espace rend l'onglet à son espace", space.selectedTabID == tab.id)
            browser.deleteSpace(other)
        }
        browser.close(tab, force: true)
    }

    /// A link opened in a new tab opens one tab, with its page: ⌘-click and ⌘⇧-click on a
    /// target=_blank link (the click's modifiers come back with the new tab's first load), and
    /// WebKit's own "Ouvrir le lien dans un nouvel onglet" of the context menu.
    private func testNewTabLinks(in space: Space) async {
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let links = await htmlTab("""
            <!doctype html><body style="margin:0;font:40px system-ui">
            <a id="a" href="https://example.com/?via=cmdblank" target="_blank" style="display:block;padding:40px">⌘-clic _blank</a>
            <a id="b" href="https://example.com/?via=cmdshiftblank" target="_blank" style="display:block;padding:40px">⌘⇧-clic _blank</a>
            <a id="c" href="https://example.com/?via=plain" style="display:block;padding:40px">⌘-clic</a>
            </body>
            """, in: space)
        browser.select(links)
        await sleep(0.5)
        func opened(_ before: [Tab]) -> String {
            space.tabs.filter { tab in !before.contains { $0 === tab } }.map { $0.url?.absoluteString ?? "vide" }.joined(separator: ", ")
        }
        for (selector, modifiers, marker, foreground) in [("#a", NSEvent.ModifierFlags.command, "via=cmdblank", false),
                                                         ("#b", [.command, .shift], "via=cmdshiftblank", true),
                                                         ("#c", .command, "via=plain", false)] {
            let before = space.tabs
            await click(links, selector: selector, modifiers: modifiers)
            await sleep(2.5)
            let new = space.tabs.filter { tab in !before.contains { $0 === tab } }
            let loaded = new.first?.webView?.url?.absoluteString.contains(marker) == true
            check("Nouvel onglet (\(selector), \(marker)) : un seul onglet, avec sa page, \(foreground ? "au premier plan" : "en arrière-plan")",
                  new.count == 1 && loaded && (browser.selectedTab === new.first) == foreground, opened(before))
            browser.select(links)
            await sleep(0.3)
        }

        // WebKit's own item of the context menu.
        for selector in ["#a", "#c"] {
            let before = space.tabs
            let windows = NSApp.windows.filter(\.isVisible).count
            var picked = false
            VoidWebView.menuTestHook = { menu in
                if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
                    menu.performActionForItem(at: index)
                    picked = true
                }
                DispatchQueue.main.async { menu.cancelTrackingWithoutAnimation() }
            }
            await mouse(links, selector: selector, types: [.rightMouseDown, .rightMouseUp], button: 1)
            await sleep(2.5)
            VoidWebView.menuTestHook = nil
            let new = space.tabs.filter { tab in !before.contains { $0 === tab } }
            check("Nouvel onglet (menu contextuel sur \(selector)) : un seul onglet, avec sa page, pas de fenêtre en plus",
                  picked && new.count == 1 && new.first?.webView?.url?.host() == "example.com" && NSApp.windows.filter(\.isVisible).count == windows,
                  "menu=\(picked) · \(opened(before)) · fenêtres \(windows) → \(NSApp.windows.filter(\.isVisible).count)")
            browser.select(links)
            await sleep(0.3)
        }

        // Middle click, on a plain link and on a target=_blank one.
        for (selector, marker) in [("#a", "via=cmdblank"), ("#c", "via=plain")] {
            let before = space.tabs
            await mouse(links, selector: selector, types: [.otherMouseDown, .otherMouseUp], button: 2)
            await sleep(2.5)
            let new = space.tabs.filter { tab in !before.contains { $0 === tab } }
            check("Nouvel onglet (clic milieu sur \(selector)) : un seul onglet, avec sa page, en arrière-plan",
                  new.count == 1 && new.first?.webView?.url?.absoluteString.contains(marker) == true && browser.selectedTab === links,
                  opened(before))
            browser.select(links)
            await sleep(0.3)
        }
    }

    /// Mouse events of another button than the left one, on an element of the page.
    private func mouse(_ tab: Tab, selector: String, types: [NSEvent.EventType], button: Int64) async {
        guard let webView = tab.webView, let window = webView.window,
              let p = await webView.voidCall("const r = document.querySelector(s).getBoundingClientRect(); return {x: r.left + r.width/2, y: r.top + r.height/2};",
                                             arguments: ["s": selector]) as? [String: Double] else { return }
        let location = webView.convert(NSPoint(x: p["x"]!, y: webView.isFlipped ? p["y"]! : webView.bounds.height - p["y"]!), to: nil)
        for type in types {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            // The button number of an NSEvent made by hand is 0: set on its Quartz event (a copy).
            let quartz = event.cgEvent
            quartz?.setIntegerValueField(.mouseEventButtonNumber, value: button)
            window.sendEvent(quartz.flatMap(NSEvent.init(cgEvent:)) ?? event)
            await sleep(0.08)
        }
    }

    /// Void Notes: URL, context menu with and without the app, selection, page, failed opening.
    /// Nothing is handed to macOS: the opening is replaced by `openOverride`.
    private func testVoidNotes(in space: Space) async {
        let notes = VoidNotes.shared
        defer { notes.openOverride = nil; notes.installedOverride = nil }
        func values(_ url: URL?) -> [String: String] {
            let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        }
        func contextMenu(_ webView: VoidWebView) -> NSMenuItem? {
            let menu = NSMenu()
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                webView.willOpenMenu(menu, with: event)
            }
            return menu.items.first { $0.title.contains("Void Notes") }
        }

        let source = URL(string: "https://example.com/a?q=1&r=2#x")
        let built = VoidNotes.noteURL(title: "Café & thé = 100 %", text: "a+b\nc & d", url: source)
        let decoded = values(built)
        check("Void Notes : URL voidnotes://new, valeurs restituées telles quelles",
              built?.scheme == "voidnotes" && built?.host() == "new" && decoded["title"] == "Café & thé = 100 %"
              && decoded["text"] == "a+b\nc & d" && decoded["url"] == source?.absoluteString, built?.absoluteString ?? "nil")
        let long = values(VoidNotes.noteURL(title: "t", text: String(repeating: "é", count: VoidNotes.maxTextLength + 500), url: nil))["text"] ?? ""
        check("Void Notes : texte long coupé", long.count == VoidNotes.maxTextLength + 1 && long.hasSuffix("…"), "\(long.count) caractères")

        let paragraph = String(repeating: "Le trou noir courbe la lumière autour de lui. ", count: 12)
        let tab = await htmlTab("<!doctype html><title>Page de notes</title><body><article><p id='p'>Texte choisi pour la note</p><p>\(paragraph)</p><p>\(paragraph)</p></article></body>", in: space)
        guard let webView = tab.webView else { check("Void Notes : vue web", false); return }
        browser.select(tab)
        _ = await js(tab, "const p = document.getElementById('p'); getSelection().selectAllChildren(p); p.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true})); return 'ok';")
        _ = await until(2) { !webView.contextSelection.isEmpty }
        check("Void Notes : sélection transmise au clic droit", webView.contextSelection == "Texte choisi pour la note", webView.contextSelection)

        notes.installedOverride = false
        let missing = contextMenu(webView)
        check("Void Notes absent : option visible, grisée, « nécessite Void Notes »",
              missing != nil && missing?.action == nil && missing?.isEnabled == false && missing?.title.contains("nécessite Void Notes") == true
              && missing?.toolTip == VoidNotes.missingHint, missing?.title ?? "nil")
        var opened: [URL] = []
        notes.openOverride = { opened.append($0); return true }
        browser.sendPageToNotes()
        await sleep(0.5)
        check("Void Notes absent : ⌘⇧M n'ouvre rien, message discret", opened.isEmpty && browser.toast?.message == VoidNotes.missingHint,
              browser.toast?.message ?? "nil")

        notes.installedOverride = true
        let present = contextMenu(webView)
        check("Void Notes présent : « Envoyer vers Void Notes » actif", present?.title == "Envoyer vers Void Notes" && present?.action != nil && present?.isEnabled == true,
              present?.title ?? "nil")
        if let present, let action = present.action { NSApp.sendAction(action, to: present.target, from: present) }
        _ = await until(2) { opened.count == 1 }
        let selectionNote = values(opened.last)
        check("Void Notes : sélection → texte, titre et lien de la page",
              selectionNote["text"] == "Texte choisi pour la note" && selectionNote["title"] == "Page de notes"
              && selectionNote["url"] == "https://void-selftest.example/", opened.last?.absoluteString ?? "nil")

        webView.contextSelection = ""
        check("Void Notes : sans sélection, le menu propose la page", contextMenu(webView)?.title == "Envoyer la page vers Void Notes")
        browser.sendPageToNotes()
        _ = await until(8) { opened.count == 2 }
        let pageNote = values(opened.count == 2 ? opened.last : nil)
        check("Void Notes : page → titre, lien et texte de l'article",
              pageNote["title"] == "Page de notes" && pageNote["url"] == "https://void-selftest.example/"
              && pageNote["text"]?.hasPrefix("Texte choisi pour la note\n\nLe trou noir") == true, String((pageNote["text"] ?? "nil").prefix(60)))

        let short = await htmlTab("<!doctype html><title>Courte</title><body><p>Trois mots seulement</p></body>", in: space)
        browser.select(short)
        browser.sendPageToNotes()
        _ = await until(8) { opened.count == 3 }
        let shortNote = values(opened.count == 3 ? opened.last : nil)
        check("Void Notes : page sans article → titre et lien seulement", shortNote["title"] == "Courte" && shortNote["url"] != nil && shortNote["text"] == nil,
              opened.last?.absoluteString ?? "nil")

        notes.openOverride = { _ in false }
        browser.sendPageToNotes()
        let warned = await until(8) { self.browser.toast?.message == "Impossible d'ouvrir Void Notes" }
        check("Void Notes : ouverture refusée → message discret, pas de plantage", warned, browser.toast?.message ?? "nil")
        browser.close(short)
        browser.close(tab)
    }

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

        await testPasswords(in: space)

        // 7a'. Session file: tolerant decoding, damaged file set aside, backup used.
        testSessionStore()

        // 7c. Tab lifecycle: dialogs, crashes, pinned tabs.
        await testTabLifecycle(in: space)

        // 7d. Downloads and links to other apps.
        await testDownloads(in: space)

        // 7e. Address field: shows the page actually displayed, never a navigation in progress.
        await testAddressSpoofing(in: space)

        // 7e'. Stability: HTTP authentication, media state, ad-block lists, windows, memory.
        await testStability(in: space)

        // 7f. History database: write-ahead log, no rewrite of an unchanged title, stable suggestions.
        let history = HistoryStore.shared
        check("Historique : journal WAL (écritures sans synchronisation complète)", history.journalMode == "wal", history.journalMode ?? "nil")
        let writes = history.titleWrites
        let probe = URL(string: "https://void-title.example/\(UUID().uuidString)")!   // no such row: nothing is modified
        for _ in 0..<10 { history.updateTitle(url: probe, title: "(3) Messages") }
        check("Historique : un titre inchangé n'est écrit qu'une fois", history.titleWrites - writes == 1, "\(history.titleWrites - writes) écriture(s)")
        testHistoryRetention()
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
        await testTrafficLights()
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

        // Fixes of docs/RAPPORT_BUGS.md
        await testReportFixes(in: space)

        settings.tabLayout = savedLayout
        settings.theme = savedTheme
        settings.sidebarVisible = savedSidebar
        browser.deleteSpace(other)
        browser.deleteSpace(space)   // also removes its on-disk data store
        write()
    }

    // MARK: - Fixes of docs/RAPPORT_BUGS.md

    private func testReportFixes(in space: Space) async {
        browser.switchSpace(to: space)

        // 1. A space deleted while another is shown: the user stays there, and none of its tabs
        // is selected (hence woken up) on the way out.
        let doomed = browser.addSpace(name: "Self-test à supprimer", icon: "trash")
        let asleep = (0..<3).map { i -> Tab in
            let tab = browser.openTab(url: nil, in: doomed, background: true)
            tab.url = URL(string: "https://void-doomed-\(i).example/")
            return tab
        }
        doomed.selectedTabID = asleep[0].id
        browser.switchSpace(to: space)
        let accessed = asleep.map(\.lastAccess)
        browser.deleteSpace(doomed)
        check("Suppression d'un espace en arrière-plan : on reste sur l'espace affiché", browser.currentSpaceID == space.id,
              browser.currentSpace.name)
        check("Suppression d'un espace : aucun de ses onglets n'est réveillé", asleep.map(\.lastAccess) == accessed)

        // 1 bis. The selected tab of a background space closed (an extension, the page): no switch.
        let background = browser.addSpace(name: "Self-test arrière-plan", icon: "leaf")
        let first = browser.openTab(url: nil, in: background)
        let second = browser.openTab(url: nil, in: background, background: true)
        second.url = URL(string: "https://void-bg.example/")
        browser.switchSpace(to: space)
        browser.close(first, force: true)
        check("Onglet actif d'un autre espace fermé : pas de changement d'espace, l'espace retient son voisin",
              browser.currentSpaceID == space.id && background.selectedTabID == second.id && second.isAsleep)
        browser.deleteSpace(background)

        // 9. A closed tab is never selected again (a stale suggestion).
        let closed = browser.openTab(url: nil, in: space)
        browser.close(closed, force: true)
        browser.select(closed)
        check("Onglet fermé : jamais resélectionné ni réveillé", browser.selectedTab !== closed && closed.isAsleep)

        // 13. ⌘W on a pinned tab: an ordinary tab takes its place.
        let ordinary = browser.openTab(url: nil, in: space)
        let pinned = browser.openTab(url: nil, in: space)
        browser.togglePin(pinned)
        browser.select(pinned)
        browser.close(pinned)
        check("⌘W sur un onglet épinglé : un onglet ordinaire est sélectionné",
              browser.selectedTab != nil && browser.selectedTab?.isPinned == false && pinned.isAsleep,
              browser.selectedTab?.displayTitle ?? "aucun")
        browser.close(pinned, force: true)
        browser.close(ordinary, force: true)

        // 10. Closing asks the page first (beforeunload): one with nothing to say goes at once,
        // through WebKit's answer, not the fallback delay.
        let leaving = await htmlTab("<!doctype html><body>fermer</body>", in: space, base: "https://void-close.example/")
        let asked = Date()
        browser.requestClose(leaving)
        for _ in 0..<40 where !leaving.isClosed { await sleep(0.05) }
        let delay = Date().timeIntervalSince(asked)
        check("Fermeture : la page est consultée, puis l'onglet se ferme aussitôt", leaving.isClosed && delay < 1,
              String(format: "%.2f s", delay))

        // 17. An e-mail address is looked up.
        check("Adresse : « jean@exemple.fr » → recherche", URLResolver.url(from: "jean@exemple.fr") == nil)
        check("Adresse : « localhost.fr » → https", URLResolver.url(from: "localhost.fr")?.absoluteString == "https://localhost.fr")

        // 21. ⌘N windows follow the main window's spaces.
        let secondary = BrowserWindows.shared.openNormalWindow()
        if secondary !== browser {
            let name = space.name
            space.name = "Self-test renommé"
            browser.setNeedsSave()
            check("Fenêtre ⌘N : un espace renommé l'est aussi", secondary.spaces.first { $0.id == space.id }?.name == "Self-test renommé")
            space.name = name
            browser.setNeedsSave()
            secondary.window?.close()
            browser.window?.makeKeyAndOrderFront(nil)
        }

        // 16. The session keeps each icon once, and still reads the icons of older sessions.
        let icon = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let key = SavedState.faviconKey(icon)
        let tabs = [SavedTab(id: UUID(), url: nil, title: "a", favicon: nil, faviconKey: key),
                    SavedTab(id: UUID(), url: nil, title: "b", favicon: nil, faviconKey: key),
                    SavedTab(id: UUID(), url: nil, title: "ancien", favicon: icon)]
        var state = SavedState(currentSpaceID: space.id, spaces: [SavedSpace(id: space.id, name: "s", icon: "circle", pinned: [], tabs: tabs, selectedTabID: nil)])
        state.favicons = [key: icon]
        let decoded = (try? JSONEncoder().encode(state)).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        check("Session : icônes rangées une fois, anciennes sessions lues",
              decoded.map { d in d.spaces[0].tabs.allSatisfy { d.favicon(of: $0) == icon } } ?? false)

        // 4. An extension folder holding a symbolic link is refused.
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("void-symlink-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: folder.appendingPathComponent("void-shim.js"), withDestinationURL: fm.temporaryDirectory.appendingPathComponent("void-target"))
        let refused = (try? ChromeExtensions.rejectSymbolicLinks(in: folder)) == nil
        try? fm.removeItem(at: folder)
        check("Extensions : un dossier contenant un lien symbolique est refusé", refused)

        // 5. Automatic password manager: Void steps aside only for an extension.
        let savedChoice = AppSettings.shared.passwordManager
        AppSettings.shared.passwordManager = .automatic
        check("Mots de passe : une app seule sur le Mac ne coupe pas Void",
              PasswordManager.shared.isActive == (PasswordManager.shared.managerExtensionName == nil))
        AppSettings.shared.passwordManager = savedChoice
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

        // Speed and time left, from WebKit's progress reports.
        let measured = DownloadItem(filename: "gros.zip", sourceURL: nil, browser: browser)
        measured.update(received: 0, total: 100_000_000)
        await sleep(1)
        measured.update(received: 10_000_000, total: 100_000_000)
        let status = measured.statusText
        check("Téléchargement : taille, vitesse et temps restant affichés",
              measured.bytesPerSecond > 8_000_000 && measured.bytesPerSecond < 11_000_000 && status.contains("/s") && status.contains("restantes"), status)

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

        // As Google Drive does: a hidden frame whose answer is an attachment the browser could show
        // (text, PDF), and a link to the file opening a new tab.
        let body = "Void " + String(repeating: "0123456789", count: 20_000)
        guard let (listener, port) = await startServer(ports: [8771, 18771, 28771], respond: { request in
            if request.hasPrefix("GET /fichier") {
                let name = request.hasPrefix("GET /fichier-lien") ? "lien.txt" : "cadre.txt"
                return "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            }
            let page = "<!doctype html><body style='margin:0;font:40px system-ui'><a id=l href='/fichier-lien' target=_blank style='display:block;padding:40px'>lien</a></body>"
            return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
        }) else { check("Téléchargement : serveur de test", false); return }
        defer { listener.cancel() }
        let page = (space.browser ?? browser).openTab(url: URL(string: "http://localhost:\(port)/"), in: space)
        await waitForLoad(page)
        _ = await js(page, "const f = document.createElement('iframe'); f.style.display = 'none'; f.src = '/fichier-cadre'; document.body.appendChild(f); return 1;")
        let framed = await until(8) { DownloadManager.shared.items.contains { $0.filename == "cadre.txt" && $0.state == .finished } }
        check("Téléchargement : fichier « attachment » demandé par un cadre caché", framed,
              DownloadManager.shared.items.map { "\($0.filename) \($0.state)" }.joined(separator: ", "))
        let tabsBefore = space.tabs.count
        // As a user's click would (simulated clicks need the window in front): a new tab for the file.
        _ = try? await page.webView?.evaluateJavaScript("window.open('/fichier-lien'); 1")
        let linked = await until(8) { DownloadManager.shared.items.contains { $0.filename == "lien.txt" && $0.state == .finished } }
        await sleep(0.5)
        let done = DownloadManager.shared.items.first { $0.filename == "lien.txt" }
        check("Téléchargement : lien _blank vers un fichier → téléchargé, onglet vide refermé, taille connue",
              linked && space.tabs.count == tabsBefore && done?.receivedBytes == Int64(body.utf8.count),
              "onglets \(tabsBefore) → \(space.tabs.count) · \(done?.finishedText ?? "aucun") · " + DownloadManager.shared.items.map { "\($0.filename) \($0.state)" }.joined(separator: ", "))
        check("Téléchargement : pas de pause proposée sans reprise possible (ni plages d'octets ni ETag)",
              done?.canPause == false, "canPause=\(String(describing: done?.canPause))")
        for item in DownloadManager.shared.items where ["cadre.txt", "lien.txt"].contains(item.filename) { DownloadManager.shared.cancel(item) }
        DownloadManager.shared.clearFinished()

        await testDownloadPause(in: space, folder: folder)

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

    // MARK: - Stability

    /// A local HTTP server answering each request with `respond(request)` (a whole response).
    /// Pause, resume, cancel while paused: a file sent slowly by a server that takes byte ranges.
    private func testDownloadPause(in space: Space, folder: URL) async {
        let size = 3 * 1024 * 1024
        let content = Data((0..<size).map { UInt8($0 % 251) })
        var ranges: [String] = []
        let listener: NWListener? = {
            for port: UInt16 in [8772, 18772, 28772] {
                guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else { continue }
                return l
            }
            return nil
        }()
        guard let listener else { check("Pause : serveur de test", false); return }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                var start = 0
                if let line = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
                    start = Int(line.dropFirst("range: bytes=".count).split(separator: "-").first ?? "") ?? 0
                    MainActor.assumeIsolated { ranges.append(String(start)) }
                }
                let head = (start > 0 ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(size - 1)/\(size)\r\n" : "HTTP/1.1 200 OK\r\n")
                    + "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"pause.bin\"\r\n"
                    + "Accept-Ranges: bytes\r\nETag: \"v1\"\r\nContent-Length: \(size - start)\r\nConnection: close\r\n\r\n"
                // ~1,5 Mo/s: long enough to pause in the middle.
                func send(from offset: Int) {
                    guard offset < size else { connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() }); return }
                    let end = min(size, offset + 48 * 1024)
                    connection.send(content: content.subdata(in: offset..<end), completion: .contentProcessed { error in
                        guard error == nil else { connection.cancel(); return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { send(from: end) }
                    })
                }
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in send(from: start) })
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        await sleep(0.3)
        guard let port = listener.port?.rawValue,
              let tab = space.tabs.first(where: { $0.webView != nil }) ?? space.tabs.first else { check("Pause : serveur de test", false); return }
        let source = URL(string: "http://localhost:\(port)/pause.bin")!
        let manager = DownloadManager.shared

        func start() async -> DownloadItem? {
            let before = Set(manager.items.map(\.id))
            tab.webView?.startDownload(using: URLRequest(url: source)) { manager.adopt($0, from: source, in: tab.browser) }
            _ = await until(4) { manager.items.contains { !before.contains($0.id) && $0.receivedBytes > 300_000 } }
            return manager.items.first { !before.contains($0.id) }
        }

        guard let item = await start() else { check("Pause : téléchargement lancé", false); return }
        check("Pause : proposée quand le serveur accepte les plages d'octets", item.canPause, "canPause=\(item.canPause)")
        manager.pause(item)
        _ = await until(3) { item.resumeData != nil }
        let partial = item.destination.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        let atPause = item.receivedBytes
        await sleep(0.6)
        check("Pause : transfert arrêté, fichier partiel conservé",
              item.state == .paused && item.canResume && partial > 0 && partial < size && item.receivedBytes == atPause && item.pausedText.hasPrefix("En pause"),
              "état \(item.state) · fichier \(partial) o · reçus \(atPause) → \(item.receivedBytes) · \(item.pausedText)")
        manager.resume(item)
        let finished = await until(10) { item.state == .finished }
        let file = item.destination.flatMap { try? Data(contentsOf: $0) }
        check("Pause : reprise là où elle s'était arrêtée, fichier complet et intact",
              finished && file == content && ranges.contains { (Int($0) ?? 0) > 0 },
              "état \(item.state) · \(file?.count ?? 0)/\(size) o · plages demandées \(ranges)")
        manager.cancel(item)
        manager.clearFinished()

        // Cancel while paused: no truncated file left behind.
        if let second = await start() {
            manager.pause(second)
            _ = await until(3) { second.resumeData != nil }
            let path = second.destination?.path ?? ""
            let existedPaused = FileManager.default.fileExists(atPath: path)
            manager.cancel(second)
            await sleep(0.3)
            let unfinished = UserDefaults.standard.stringArray(forKey: "unfinishedDownloads") ?? []
            check("Pause : annuler supprime le fichier incomplet", existedPaused && !FileManager.default.fileExists(atPath: path) && !unfinished.contains(path),
                  "en pause : \(existedPaused) · après : \(FileManager.default.fileExists(atPath: path))")
            manager.clearFinished()
        } else {
            check("Pause : second téléchargement lancé", false)
        }
    }

    private func startServer(ports: [UInt16], respond: @escaping @MainActor (String) -> String) async -> (NWListener, UInt16)? {
        for candidate in ports {
            guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: candidate)!) else { continue }
            var ready = false
            l.stateUpdateHandler = { if case .ready = $0 { MainActor.assumeIsolated { ready = true } } }
            l.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let response = MainActor.assumeIsolated { respond(request) }
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            l.start(queue: .main)
            for _ in 0..<20 where !ready { await sleep(0.1) }
            if ready { return (l, candidate) }
            l.cancel()
        }
        return nil
    }

    private func pageText(_ tab: Tab) async -> String {
        await js(tab, "return document.body ? document.body.innerText.trim() : '';") as? String ?? ""
    }

    /// A page element goes fullscreen (a video's button): WebKit moves the web view into its own
    /// window. A media change meanwhile (the video starts: keep-alive tabs change, the page area
    /// re-syncs) must leave it there, and it must come back to the page area on exit.
    private func testElementFullscreen(in space: Space) async {
        let tab = await htmlTab("<!doctype html><body><div id=v style='width:320px;height:180px;background:#000'></div></body>", in: space)
        guard let webView = tab.webView else { check("Plein écran : vue web", false); return }
        let host = webView.superview
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await sleep(0.5)
        // Page world: requestFullscreen needs the user gesture WebKit grants to app-run scripts.
        let request = try? await webView.callAsyncJavaScript(
            "try { await document.getElementById('v').requestFullscreen(); return 'ok'; } catch (e) { return String(e); }",
            contentWorld: .page)
        for _ in 0..<50 where !tab.isInElementFullscreen { await sleep(0.1) }
        await sleep(1.5)
        let entered = tab.isInElementFullscreen && webView.window != nil && webView.window !== browser.window
        check("Plein écran : la vue web passe dans la fenêtre plein écran de WebKit", entered,
              "état=\(webView.fullscreenState.rawValue) requête=\(String(describing: request))")
        guard entered else { return }

        tab.isPlayingVideo = true
        await sleep(0.8)
        check("Plein écran : un changement de lecture ne ramène pas la vue web dans la fenêtre (écran noir)",
              webView.window != nil && webView.window !== browser.window)

        _ = try? await webView.callAsyncJavaScript("await document.exitFullscreen();", contentWorld: .page)
        for _ in 0..<50 where tab.isInElementFullscreen { await sleep(0.1) }
        await sleep(1)
        tab.isPlayingVideo = false
        await sleep(0.3)
        check("Plein écran : en sortant, la page revient à sa place", webView.window === browser.window && webView.superview === host
              && host?.subviews.last === webView)

        // Closing the tab while it's fullscreen: WebKit's fullscreen window goes away.
        _ = try? await webView.callAsyncJavaScript("await document.getElementById('v').requestFullscreen();", contentWorld: .page)
        for _ in 0..<50 where !tab.isInElementFullscreen { await sleep(0.1) }
        await sleep(1.5)
        let fullscreenWindow = webView.window
        browser.close(tab)
        await sleep(1.5)
        check("Plein écran : fermer l'onglet ferme aussi la fenêtre plein écran", fullscreenWindow !== browser.window
              && fullscreenWindow?.isVisible == false && tab.webView == nil,
              "fenêtre=\(fullscreenWindow.map { String(describing: type(of: $0)) } ?? "nil") visible=\(fullscreenWindow?.isVisible ?? false)")
    }

    /// A page with a video that plays without network (a canvas stream).
    private static let streamPage = """
        <!doctype html><body style='margin:0'><canvas id=c width=160 height=90></canvas><div id=slot></div><script>
        const c = document.getElementById('c'), x = c.getContext('2d'); let n = 0;
        setInterval(() => { x.fillStyle = 'hsl(' + (n++ * 12) + ',80%,50%)'; x.fillRect(0, 0, 160, 90); }, 40);
        window.makeVideo = (shadow) => {
          const v = document.createElement('video');
          v.id = 'v'; v.muted = true; v.style.cssText = 'width:320px;height:180px;display:block';
          v.srcObject = c.captureStream(25);
          if (shadow) { const host = document.createElement('x-player'); host.attachShadow({ mode: 'open' }).appendChild(v); slot.appendChild(host); }
          else slot.appendChild(v);
          window.video = v;
        };
        </script></body>
        """

    /// Waits until `condition` holds (or `timeout`).
    private func until(_ timeout: Double = 4, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<Int(timeout * 10) {
            if condition() { return true }
            await sleep(0.1)
        }
        return condition()
    }

    private func key(_ window: NSWindow, code: UInt16, scalar: Int) {
        let chars = String(UnicodeScalar(scalar)!)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) {
                window.sendEvent(e)
            }
        }
    }

    /// Video players: media state, keys, context menu download.
    private func testPlayers(in space: Space) async {
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 1. The page changes its address without reloading (next video): pausing must still be seen.
        let spa = await htmlTab(Self.streamPage, in: space)
        _ = try? await spa.webView?.callAsyncJavaScript("makeVideo(false); await video.play(); return 1;", contentWorld: .page)
        let played = await until { spa.isPlayingVideo }
        _ = try? await spa.webView?.callAsyncJavaScript("history.pushState({}, '', '/video-suivante'); await new Promise(r => setTimeout(r, 300)); video.pause(); return 1;", contentWorld: .page)
        let paused = await until { !spa.isPlayingVideo }
        check("Lecteurs : pause vue après un changement d'adresse sans rechargement", played && paused,
              "lecture=\(played) pause=\(paused) entrées=\(spa.mediaFrames.count)")

        // 2. A player inside a shadow root (web component): play and pause are seen.
        let shadow = await htmlTab(Self.streamPage, in: space)
        _ = try? await shadow.webView?.callAsyncJavaScript("makeVideo(true); return 1;", contentWorld: .page)
        await sleep(0.6)
        _ = try? await shadow.webView?.callAsyncJavaScript("await video.play(); return 1;", contentWorld: .page)
        let shadowPlayed = await until { shadow.isPlayingVideo }
        _ = try? await shadow.webView?.callAsyncJavaScript("video.pause(); return 1;", contentWorld: .page)
        let shadowPaused = await until { !shadow.isPlayingVideo }
        check("Lecteurs : lecteur dans un shadow DOM, lecture et pause vues", shadowPlayed && shadowPaused,
              "lecture=\(shadowPlayed) pause=\(shadowPaused)")
        browser.close(shadow)
        browser.close(spa)

        // 3. Keys the page leaves unhandled: dropped (no system beep), handled ones still work.
        let fixed = await htmlTab("<!doctype html><body style='overflow:hidden;margin:0'><div style='height:100px'>lecteur</div></body>", in: space)
        if let webView = fixed.webView, let window = webView.window {
            window.makeFirstResponder(webView)
            let before = webView.droppedKeyDowns
            key(window, code: 124, scalar: NSRightArrowFunctionKey)
            let dropped = await until(2) { webView.droppedKeyDowns > before }
            check("Clavier : flèche que la page ne traite pas → ignorée sans bip", dropped, "ignorées=\(webView.droppedKeyDowns - before)")
            // Keys in a row: the page answers the first one after the second has been sent.
            let beforeBurst = webView.droppedKeyDowns
            for _ in 0..<4 { key(window, code: 124, scalar: NSRightArrowFunctionKey) }
            let burst = await until(2) { webView.droppedKeyDowns - beforeBurst == 4 }
            check("Clavier : flèches enchaînées que la page ne traite pas → toutes ignorées", burst, "ignorées=\(webView.droppedKeyDowns - beforeBurst)/4")
        } else { check("Clavier : vue web", false) }
        browser.close(fixed)
        let scrolling = await htmlTab("<!doctype html><body style='margin:0;height:6000px'>long</body>", in: space)
        if let webView = scrolling.webView, let window = webView.window {
            window.makeFirstResponder(webView)
            let before = webView.droppedKeyDowns
            key(window, code: 125, scalar: NSDownArrowFunctionKey)
            await sleep(0.8)
            let y = await js(scrolling, "return window.scrollY;") as? Double ?? 0
            check("Clavier : flèche traitée par la page (défilement) → inchangée", y > 0 && webView.droppedKeyDowns == before, "scrollY=\(y)")
        }
        browser.close(scrolling)

        // 4. Right-click → "Download Linked File": the download starts.
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("void-menu-dl-\(UUID().uuidString)")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        let savedFolder = settings.downloadFolderPath
        settings.downloadFolderPath = folder.path
        defer { settings.downloadFolderPath = savedFolder; try? fm.removeItem(at: folder) }
        let links = await htmlTab("<!doctype html><body style='margin:0'><a id=l href='data:application/octet-stream;base64,Vm9pZA==' style='font:40px system-ui;display:inline-block;margin:40px'>fichier</a></body>", in: space)
        var identifiers: [String] = []
        var picked = false
        var saveAsFollows = false
        VoidWebView.menuTestHook = { menu in
            identifiers = menu.items.compactMap(\.identifier?.rawValue)
            if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierDownloadLinkedFile" }) {
                saveAsFollows = menu.items.indices.contains(index + 1) && menu.items[index + 1].title == "Télécharger le fichier lié sous…"
                menu.performActionForItem(at: index)
                picked = true
            }
            DispatchQueue.main.async { menu.cancelTrackingWithoutAnimation() }
        }
        let count = DownloadManager.shared.items.count
        if let webView = links.webView, let window = webView.window,
           let p = await webView.voidCall("const r = document.getElementById('l').getBoundingClientRect(); return {x: r.left + r.width/2, y: r.top + r.height/2};") as? [String: Double] {
            let location = webView.convert(NSPoint(x: p["x"]!, y: webView.isFlipped ? p["y"]! : webView.bounds.height - p["y"]!), to: nil)
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
                await sleep(0.1)
            }
        }
        let started = await until(6) { DownloadManager.shared.items.count > count }
        let item = started ? DownloadManager.shared.items.first : nil
        _ = await until(4) { item?.state == .finished }
        check("Clic droit → Télécharger le fichier lié : le téléchargement démarre et se termine", picked && item?.state == .finished,
              "menu=\(picked ? "ok" : identifiers.joined(separator: ",")) état=\(String(describing: item?.state))")
        check("Clic droit sur un lien : « Télécharger le fichier lié sous… » juste après", saveAsFollows)
        VoidWebView.menuTestHook = nil
        if let item { DownloadManager.shared.cancel(item); DownloadManager.shared.clearFinished() }
        browser.close(links)
    }

    /// The command bar over a docked sidebar: centered on the page, not on the window.
    private func snapshotCommandBar(in space: Space) async {
        let settings = AppSettings.shared
        let saved = (settings.tabLayout, settings.sidebarVisible, settings.sidebarAutoHide)
        settings.tabLayout = .sidebar
        settings.sidebarVisible = true
        settings.sidebarAutoHide = false
        browser.window?.makeKeyAndOrderFront(nil)
        let tab = await htmlTab("<!doctype html><body>page</body>", in: space)
        browser.showCommandBar(.currentTab)
        await sleep(1)
        await snapshotWindow("command-bar")
        browser.commandBar = nil
        await sleep(0.3)
        browser.commandBar = CommandBarRequest(mode: .currentTab, text: "10 km en miles")
        await sleep(1)
        await snapshotWindow("command-bar-conversion")
        browser.commandBar = nil
        browser.close(tab)
        (settings.tabLayout, settings.sidebarVisible, settings.sidebarAutoHide) = saved
    }

    private func testStability(in space: Space) async {
        // 1. HTTP authentication. /open/… answers without it; everything else asks for void / secret.
        let expected = "Authorization: Basic " + Data("void:secret".utf8).base64EncodedString()
        let server = await startServer(ports: [8766, 18766, 28766]) { request in
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            func page(_ status: String, _ body: String, _ extra: String = "") -> String {
                "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n\(extra)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            }
            if path.hasPrefix("/open/") { return page("200 OK", "<!doctype html><title>\(path)</title><body>\(path)</body>") }
            if request.contains(expected) { return page("200 OK", "<!doctype html><body>auth-ok</body>") }
            return page("401 Unauthorized", "<!doctype html><body>auth-required</body>", "WWW-Authenticate: Basic realm=\"Void test\"\r\n")
        }
        guard let (listener, port) = server else { check("Stabilité : serveur de test", false); return }
        defer { listener.cancel() }
        let base = "http://127.0.0.1:\(port)"

        let shown = await htmlTab("<!doctype html><body>devant</body>", in: space)
        let hidden = browser.openTab(url: URL(string: base + "/prive")!, in: space, background: true)
        await waitForLoad(hidden)
        let hiddenText = await pageText(hidden)
        check("Authentification HTTP : onglet en arrière-plan → page 401 du serveur, sans dialogue",
              hiddenText == "auth-required" && browser.window?.attachedSheet == nil && browser.selectedTab === shown, hiddenText)

        browser.select(hidden)
        browser.reload()
        var sheet: NSWindow?
        for _ in 0..<30 where sheet == nil { await sleep(0.1); sheet = browser.window?.attachedSheet }
        if let sheet {
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let all = sheet.contentView.map(views) ?? []
            let texts = all.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
            let user = texts.first { !($0 is NSSecureTextField) }, password = texts.first { $0 is NSSecureTextField }
            user?.stringValue = "void"
            password?.stringValue = "secret"
            let button = all.compactMap { $0 as? NSButton }.first { $0.title == "Se connecter" }
            button?.performClick(nil)
            await waitForLoad(hidden)
            let text = await pageText(hidden)
            check("Authentification HTTP : l'onglet affiché demande les identifiants, la page s'ouvre", text == "auth-ok",
                  "champs=\(user != nil && password != nil) bouton=\(button != nil) page=\(text)")
        } else {
            check("Authentification HTTP : l'onglet affiché demande les identifiants, la page s'ouvre", false, "aucun dialogue")
        }
        browser.close(hidden, force: true)

        // 2. A playing video removed from the page: the tab stops counting as playing.
        let video = await htmlTab("""
            <!doctype html><body><video id="v" muted autoplay playsinline width="320" height="180"></video>
            <script>
              const c = document.createElement('canvas'); c.width = 320; c.height = 180;
              const g = c.getContext('2d'); let n = 0;
              setInterval(() => { g.fillStyle = 'hsl(' + (n++ % 360) + ',80%,50%)'; g.fillRect(0, 0, 320, 180); }, 50);
              const v = document.getElementById('v'); v.srcObject = c.captureStream(25); v.play();
            </script></body>
            """, in: space, base: "https://void-video.example/")
        for _ in 0..<20 where !video.isPlayingVideo { await sleep(0.25) }
        let wasPlaying = video.isPlayingVideo
        _ = await js(video, "document.getElementById('v').remove(); return 1;")
        for _ in 0..<32 where video.isPlayingVideo { await sleep(0.25) }
        check("Vidéo retirée de la page en cours de lecture : l'onglet n'est plus « en lecture »", wasPlaying && !video.isPlayingVideo,
              "lecture avant=\(wasPlaying) après=\(video.isPlayingVideo)")
        browser.close(video, force: true)

        // 3. Quick successive changes of the blocker's allowlist: one list installed, the last one.
        let settings = AppSettings.shared
        if settings.adBlockEnabled {
            let saved = settings.adBlockAllowlist
            var identifiers = Set<String>()
            for i in 1...4 {
                settings.adBlockAllowlist = saved + ["void-course-\(i).example"]
                identifiers.insert(ContentRules.adBlockIdentifier(allowlist: settings.adBlockAllowlist))
            }
            let last = ContentRules.adBlockIdentifier(allowlist: settings.adBlockAllowlist)
            await sleep(2)
            let installed = ContentRules.shared.installedIdentifiers.filter { $0.hasPrefix("void-adblock") }
            check("Bloqueur : changements rapides → une seule liste installée, la dernière", installed == [last], installed.sorted().joined(separator: ", "))
            settings.adBlockAllowlist = saved
            await sleep(1.5)
            let restored = ContentRules.shared.installedIdentifiers.filter { $0.hasPrefix("void-adblock") }
            check("Bloqueur : liste d'origine rétablie", restored == [ContentRules.adBlockIdentifier(allowlist: saved)], restored.sorted().joined(separator: ", "))
            // The test's compiled lists don't stay in WebKit's store.
            for identifier in identifiers { try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) }
        }

        // 4. ⌘W on a pinned tab in PiP, shown again before PiP is left: it keeps its page.
        let pip = await htmlTab("<!doctype html><body>pip</body>", in: space, base: "https://void-pip2.example/")
        browser.togglePin(pip)
        browser.select(pip)
        pip.isInPiP = true
        browser.closeCurrentTab()
        browser.select(pip)
        await sleep(1.5)
        check("⌘W sur un épinglé en PiP puis retour immédiat : la page reste", !pip.isAsleep && browser.selectedTab === pip)
        browser.close(pip, force: true)

        // 5. The login form of the previous page is forgotten when another page commits.
        let login = await htmlTab("<!doctype html><body>a</body>", in: space, base: "https://void-login-reset.example/")
        login.loginHost = "void-login-reset.example"
        login.webView?.loadHTMLString("<!doctype html><body>b</body>", baseURL: URL(string: "https://void-autre-page.example/"))
        await waitForLoad(login)
        check("Mots de passe : formulaire de la page précédente oublié au changement de page", login.loginHost == nil && login.loginFrame == nil)
        browser.close(login, force: true)

        // 6. Memory pressure: idle background tabs sleep right away, the tab shown stays.
        let sleepSetting = settings.sleepInactiveTabs
        settings.sleepInactiveTabs = true
        let idle = await htmlTab("<!doctype html><body>idle</body>", in: space, base: "https://void-idle.example/")
        let front = await htmlTab("<!doctype html><body>front</body>", in: space, base: "https://void-front2.example/")
        BrowserWindows.shared.memoryPressure(critical: true)
        await sleep(1)
        check("Mémoire critique : onglets inactifs en veille, l'onglet affiché reste", idle.isAsleep && !front.isAsleep)
        settings.sleepInactiveTabs = sleepSetting
        browser.close(idle, force: true)

        // 7. A space deleted in the main window, the only one of a ⌘N window: that window moves to another space.
        let current = browser.currentSpace
        let extra = browser.addSpace(name: "Self-test 2", icon: "star")
        let secondary = BrowserWindows.shared.openNormalWindow()
        if secondary !== browser {
            secondary.spaces.removeAll { $0.id != extra.id }
            secondary.currentSpaceID = extra.id
            secondary.openTab(url: nil)
            browser.deleteSpace(extra)
            // Then it shows the main window's spaces again (they are kept in sync).
            check("Espace supprimé, seul espace d'une fenêtre ⌘N : la fenêtre passe à un autre espace",
                  !secondary.spaces.contains { $0.id == extra.id } && secondary.spaces.map(\.id) == browser.spaces.map(\.id)
                    && secondary.currentSpaceID != extra.id && secondary.spaces.contains { $0.id == secondary.currentSpaceID },
                  secondary.spaces.map(\.name).joined(separator: ", "))
            secondary.window?.close()
        } else {
            browser.deleteSpace(extra)
            check("Espace supprimé, seul espace d'une fenêtre ⌘N : la fenêtre passe à un autre espace", false, "fenêtre ⌘N non ouverte")
        }
        browser.switchSpace(to: current)
        browser.window?.makeKeyAndOrderFront(nil)

        // 8. Main window closed: every page stops, and comes back with its history when shown again.
        let history = browser.openTab(url: URL(string: base + "/open/1")!, in: space)
        await waitForLoad(history)
        history.load(URL(string: base + "/open/2")!)
        await waitForLoad(history)
        browser.windowClosed()
        let allAsleep = browser.allTabs.allSatisfy(\.isAsleep)
        browser.select(history)
        await waitForLoad(history)
        check("Fenêtre principale fermée : pages arrêtées, puis rendues avec leur historique",
              allAsleep && history.webView?.url?.path() == "/open/2" && history.canGoBack,
              "en veille=\(allAsleep) page=\(history.webView?.url?.path() ?? "nil") retour=\(history.canGoBack)")
        browser.close(history, force: true)
        browser.close(front, force: true)
        browser.close(shown, force: true)
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
        // In the sidebar layout: the top bar keeps the window unmovable all the time.
        let layoutBefore = AppSettings.shared.tabLayout
        AppSettings.shared.tabLayout = .sidebar
        await sleep(0.5)
        defer { AppSettings.shared.tabLayout = layoutBefore }
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

        await testTopBarMouse(in: space)
        await testLayoutSwitch(in: space)

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

    /// Tabs moved between the sidebar and the top, animated as in Settings: the page stays in the
    /// window (both page areas exist during the animation; the old one used to keep the web view).
    private func testLayoutSwitch(in space: Space) async {
        let settings = AppSettings.shared
        let savedLayout = settings.tabLayout
        defer { settings.tabLayout = savedLayout }
        for _ in 0..<20 where browser.window == nil { await sleep(0.25) }
        browser.switchSpace(to: space)
        let tab = await htmlTab("<!doctype html><title>Disposition</title><body>Page</body>", in: space)
        var lost: [String] = []
        for i in 0..<6 {
            withAnimation(Theme.spring) { settings.tabLayout = settings.tabLayout == .sidebar ? .top : .sidebar }
            // Quick switches too, before the previous animation ends.
            await sleep(i % 2 == 0 ? 0.1 : 1.2)
            if i % 2 == 1, tab.webView?.window !== browser.window { lost.append("\(i) → \(settings.tabLayout.rawValue)") }
        }
        await sleep(1.2)
        if tab.webView?.window !== browser.window { lost.append("fin") }
        check("Disposition des onglets : la page reste affichée en passant de la barre latérale au haut (et retour)",
              lost.isEmpty, lost.isEmpty ? "" : "page hors de la fenêtre : \(lost.joined(separator: ", "))")
        browser.close(tab, force: true)
    }

    /// Top bar, with mouse events posted to the window: a tab dragged moves the tab and not the
    /// window; the bar's empty places move the window. (The window server's own title bar drag
    /// can't be reached this way: that the window is unmovable by the system covers it.)
    private func testTopBarMouse(in space: Space) async {
        let settings = AppSettings.shared
        let savedLayout = settings.tabLayout
        defer { settings.tabLayout = savedLayout }
        settings.tabLayout = .top
        for _ in 0..<20 where browser.window == nil { await sleep(0.25) }
        guard let window = browser.window, let content = window.contentView else { return check("Barre du haut : fenêtre introuvable", false) }
        browser.switchSpace(to: space)
        while space.tabs.count > 3 { browser.close(space.tabs.last!, force: true) }
        while space.tabs.count < 3 { browser.openTab(url: nil, in: space, background: true) }
        browser.select(space.tabs[0])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await sleep(1.5)
        check("Barre du haut : la fenêtre n'est pas déplaçable par le système (seulement par les zones vides)", !window.isMovable,
              "app active=\(NSApp.isActive) fenêtre principale=\(window.isKeyWindow)")

        func post(_ type: NSEvent.EventType, _ topLeft: CGPoint) {
            let location = NSPoint(x: topLeft.x, y: content.bounds.height - topLeft.y)
            if let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        func drag(from start: CGPoint, by dx: CGFloat, steps: Int) async {
            post(.leftMouseDown, start)
            await sleep(0.1)
            for i in 1...steps {
                post(.leftMouseDragged, CGPoint(x: start.x + dx * CGFloat(i) / CGFloat(steps), y: start.y))
                await sleep(0.03)
            }
            post(.leftMouseUp, CGPoint(x: start.x + dx, y: start.y))
            await sleep(0.8)
        }

        // A tab: the second one, dragged past the third.
        let second = space.tabs[1]
        if let frame = TabReorder.windowFrames[second.id], let third = TabReorder.windowFrames[space.tabs[2].id] {
            let origin = window.frame.origin
            await drag(from: CGPoint(x: frame.midX, y: frame.midY), by: third.maxX - frame.midX + 10, steps: 12)
            let index = space.tabs.firstIndex { $0 === second }
            check("Barre du haut : glisser un onglet le déplace, la fenêtre ne bouge pas",
                  index == 2 && window.frame.origin == origin, "position \(index.map(String.init) ?? "?") · fenêtre \(NSStringFromPoint(origin)) → \(NSStringFromPoint(window.frame.origin))")
        } else {
            check("Barre du haut : onglets non mesurés", false)
        }

        // An empty place: between the last tab's ＋ and the tools on the right.
        let lastTab = space.tabs.compactMap { TabReorder.windowFrames[$0.id] }.map(\.maxX).max() ?? 0
        let empty = CGPoint(x: (lastTab + 40 + content.bounds.width - 110) / 2, y: 22)
        let origin = window.frame.origin
        await drag(from: empty, by: 40, steps: 1)
        let moved = window.frame.origin
        check("Barre du haut : glisser dans une zone vide déplace la fenêtre", moved.x == origin.x + 40 && moved.y == origin.y,
              "x=\(Int(empty.x)) · \(NSStringFromPoint(origin)) → \(NSStringFromPoint(moved))")
        window.setFrameOrigin(origin)
    }

    /// What the Chrome Web Store's page offers in Void: the store's button replaced by Void's.
    private func testWebStorePage(in space: Space) async {
        guard #available(macOS 15.4, *) else { return }
        let tab = browser.openTab(url: URL(string: "https://chromewebstore.google.com/detail/proton-pass-free-password/ghmbeldphafepmbegfdlkpapadhbakde"), in: space)
        await waitForLoad(tab, timeout: 30)
        if tab.url?.host() == "consent.google.com" {
            // A fresh profile: Google's cookie page first — refused.
            _ = await js(tab, "const b = [...document.querySelectorAll('button')].find(b => /reject all|tout refuser/i.test(b.innerText)); if (b) b.click(); return !!b;")
            await waitForLoad(tab, timeout: 30)
        }
        var ours: [String: Any]?
        for _ in 0..<40 {
            ours = await js(tab, "const b = document.querySelector('button[data-void-store]'); return b ? {text: b.innerText.trim(), disabled: b.disabled, visible: b.offsetWidth > 0} : null;") as? [String: Any]
            if ours != nil { break }
            await sleep(0.25)
        }
        let expected = ExtensionManager.shared.isInstalled(chromeID: "ghmbeldphafepmbegfdlkpapadhbakde") ? "Retirer de Void" : "Ajouter à Void"
        check("Chrome Web Store : « \(expected) » à la place du bouton de Chrome", ours?["text"] as? String == expected
              && ours?["disabled"] as? Bool == false && ours?["visible"] as? Bool == true, ours.map { "\($0)" } ?? "bouton absent")
        let savedLayout = AppSettings.shared.tabLayout
        AppSettings.shared.tabLayout = .top
        await sleep(1.5)
        await snapshotWindow("store", tab: tab)
        AppSettings.shared.tabLayout = savedLayout
        browser.close(tab, force: true)

        // Settings → Extensions.
        let savedPanel = UserDefaults.standard.string(forKey: "settingsPanel")
        UserDefaults.standard.set("extensions", forKey: "settingsPanel")
        browser.openSettingsAction?()
        await sleep(1.5)
        if let settingsWindow = NSApp.windows.first(where: { $0.isVisible && $0 !== browser.window && $0.title != "Void" && !($0 is NSPanel) }) {
            await snapshotWindow("settings-extensions", window: settingsWindow)
            settingsWindow.performClose(nil)
        }
        UserDefaults.standard.set(savedPanel, forKey: "settingsPanel")
    }

    // MARK: - Chrome extensions

    /// The extensions already installed (extensions.json) are all running shortly after launch,
    /// and their button is in the chrome. Meant for a copy of a real profile.
    private func testInstalledExtensionsLoad() async {
        guard #available(macOS 15.4, *) else { return }
        let manager = ExtensionManager.shared
        let records = manager.installedRecords
        for _ in 0..<40 where manager.contexts.count < records.count { await sleep(0.25) }
        check("Extensions installées : chargées au lancement", !records.isEmpty && manager.contexts.count == records.count,
              "\(manager.contexts.count) / \(records.count) — activées=\(AppSettings.shared.extensionsEnabled) démarré=\(manager.isStarted) \(manager.lastError ?? "")")
        for _ in 0..<20 where browser.window == nil { await sleep(0.25) }
        if browser.currentSpace.allTabs.isEmpty { _ = await htmlTab("<!doctype html><title>Page</title><body>Page</body>", in: browser.currentSpace, base: "https://example.com/") }
        let savedLayout = AppSettings.shared.tabLayout
        for layout in [TabLayout.top, .sidebar] {
            AppSettings.shared.tabLayout = layout
            await sleep(1.5)
            await snapshotWindow("installees-\(layout.rawValue)")
        }
        AppSettings.shared.tabLayout = savedLayout
    }

    /// Pages older than the chosen period leave the history. The setting is left as it is:
    /// a shorter one would prune the real history.
    private func testHistoryRetention() {
        let days = Double(AppSettings.shared.historyRetention.rawValue)
        let recentProbe = URL(string: "https://void-recent.example/\(UUID().uuidString)")!
        let oldProbe = URL(string: "https://void-old.example/\(UUID().uuidString)")!
        HistoryStore.shared.importEntries([
            HistoryEntry(url: recentProbe, title: "", visits: 1, lastVisit: Date().addingTimeInterval(-(days - 2) * 86_400)),
            HistoryEntry(url: oldProbe, title: "", visits: 1, lastVisit: Date().addingTimeInterval(-(days + 2) * 86_400)),
        ])
        let kept = HistoryStore.shared.search(recentProbe.absoluteString, limit: 1).contains { $0.url == recentProbe }
        let pruned = !HistoryStore.shared.search(oldProbe.absoluteString, limit: 1).contains { $0.url == oldProbe }
        if let entry = HistoryStore.shared.search(recentProbe.absoluteString, limit: 1).first { HistoryStore.shared.delete(entry) }
        check("Historique : effacé au-delà de « \(AppSettings.shared.historyRetention.label) », gardé en deçà", kept && pruned, "gardée=\(kept) effacée=\(pruned)")
    }

    /// 7a. Autofill stays on the origin the credentials belong to (no Touch ID here: the
    /// injection step is called directly, with a throw-away password).
    private func testPasswords(in space: Space) async {
        let settings = AppSettings.shared
        let savedManager = settings.passwordManager
        defer { settings.passwordManager = savedManager }
        settings.passwordManager = .other
        let otherManager = await htmlTab("""
            <!doctype html><body><form><input type="email"><input type="password"></form></body>
            """, in: space, base: "https://void-login-c.example/")
        await sleep(0.8)
        check("Mots de passe : laissés à un autre gestionnaire, Void ignore le formulaire", otherManager.loginHost == nil, otherManager.loginHost ?? "nil")
        settings.passwordManager = .void
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
        settings.passwordManager = .automatic
        let other = PasswordManager.shared.otherManagerName
        NSLog("[Void features] gestionnaire : extension=%@ app=%@", PasswordManager.shared.managerExtensionName ?? "aucune",
              PasswordManager.shared.installedApp?.name ?? "aucune")
        let managerExtension = PasswordManager.shared.managerExtensionName
        check("Mots de passe : mode automatique, Void s'efface devant une extension de mots de passe (pas devant une app seule)",
              PasswordManager.shared.isActive == (managerExtension == nil),
              "détecté : \(other ?? "aucun"), extension : \(managerExtension ?? "aucune")")
    }

    /// A password manager extension (Proton Pass) draws its icon in the login field and, on focus,
    /// its dropdown (an iframe of its own page). Meant for a copy of a real profile.
    private func testExtensionInlineAutofill(in space: Space) async {
        guard #available(macOS 15.4, *) else { return }
        let manager = ExtensionManager.shared
        for _ in 0..<40 where manager.contexts.count < manager.installedRecords.count { await sleep(0.25) }
        for _ in 0..<20 where browser.window == nil { await sleep(0.25) }
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let tab = await htmlTab("""
            <!doctype html><title>Connexion</title><body style="font:16px system-ui;padding:40px">
            <header><a href="/">Accueil</a> <nav><a href="/a">Statut</a> <a href="/b">Créer</a> <a href="/c">Gérer</a> <a href="/d">Aide</a></nav>
            <input type="search" name="q" placeholder="Rechercher"></header>
            <main><h1>Mon compte</h1><h2>J'ai déjà un compte</h2><p>Me connecter avec mon compte</p>
            <form method="post" action="/login"><label>Courriel<br><input id="u" name="username" type="text" autocomplete="username" style="width:400px;height:36px"></label><br><br>
            <label>Mot de passe<br><input id="p" name="password" type="password" style="width:400px;height:36px"></label><br><br>
            <button type="submit">Me connecter</button></form><p><a href="/oubli">Mot de passe oublié ?</a></p>
            <p>FranceConnect est la solution proposée par l'État.</p><ul><li><a href="/1">Un</a></li><li><a href="/2">Deux</a></li><li><a href="/3">Trois</a></li></ul></main>
            <footer><p>Pied de page</p><a href="/m">Mentions</a> <a href="/c">Contact</a> <a href="/p">Plan</a></footer></body>
            """, in: space, base: "https://login.urssaf.fr/")
        browser.select(tab)
        let probe = """
            const all = [...document.querySelectorAll('*')];
            const custom = all.filter(e => e.tagName.includes('-')).map(e => e.tagName.toLowerCase() + (e.shadowRoot ? '(shadow)' : ''));
            const frames = [...document.querySelectorAll('iframe')].map(f => f.src || '(sans src)');
            const deep = [];
            for (const e of all) if (e.shadowRoot) for (const f of e.shadowRoot.querySelectorAll('iframe')) deep.push(f.src);
            return JSON.stringify({ custom, frames, deep, active: document.activeElement && document.activeElement.id,
                                    uAttrs: [...document.getElementById('u').attributes].map(a => a.name).join(',') });
            """
        await sleep(6)
        NSLog("[Void features] proton avant focus : %@", (await js(tab, probe) as? String) ?? "nil")
        await click(tab, selector: "#u", modifiers: [], move: true)
        await sleep(4)
        let after = (await js(tab, probe) as? String) ?? "nil"
        NSLog("[Void features] proton après focus : %@", after)
        await snapshotWindow("proton-champ", tab: tab)
        // Proton Pass: its icon is a protonpass-control-… element; the field gets data-protonpass-base-css.
        check("Extension de mots de passe : icône dans le champ de connexion",
              after.contains("protonpass-control") && after.contains("data-protonpass-base-css"), after)
    }

    /// The popup of each installed extension, over a web page, opened twice: shown and not empty.
    /// Meant for a copy of a real profile (Proton Pass: WebKit loses its service worker a few seconds
    /// after launch, see ExtensionManager.watchBackground; the popup then opened empty and closed).
    private func testInstalledPopups(in space: Space) async {
        guard #available(macOS 15.4, *) else { return }
        let manager = ExtensionManager.shared
        let records = manager.installedRecords
        for _ in 0..<40 where manager.contexts.count < records.count { await sleep(0.25) }
        for _ in 0..<20 where browser.window == nil { await sleep(0.25) }
        _ = await htmlTab("<!doctype html><title>Sous le popup</title><body>Page</body>", in: space, base: "https://example.com/")
        await sleep(10)   // past the moment WebKit loses service workers
        for context in manager.contexts {
            let name = context.webExtension.displayName ?? context.uniqueIdentifier
            for round in 1...2 {
                manager.performAction(context, in: browser)
                await sleep(4)
                let popover = manager.shownPopover
                let text = try? await manager.shownPopupWebView?.evaluateJavaScript("document.body ? document.body.innerText.length : -1")
                check("Popup « \(name) » (ouverture \(round)) : affiché, non vide",
                      popover?.isShown == true && ((text as? Int) ?? 0) > 0,
                      "affiché=\(popover?.isShown ?? false) taille=\(NSStringFromSize(popover?.contentSize ?? .zero)) texte=\(text.map { "\($0)" } ?? "nil")")
                popover?.performClose(nil)
                await sleep(1.5)
            }
        }
    }

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
             "action": {"default_title": "Void Self-Test", "default_popup": "popup.html"}, "options_page": "options.html"}
            """,
            "background.js": """
            // Like Proton Pass: an API WebKit lacks, used right away, and the API globals hidden
            // once started (extension-shim.js must keep both working).
            chrome.runtime.onUpdateAvailable.addListener(() => {});
            setTimeout(() => { for (const name of ["chrome", "browser"]) globalThis[name] = new Proxy({}, {}); }, 0);
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
            "options.js": "chrome.tabs.query({}, (tabs) => { chrome.runtime.sendMessage({kind: 'tabs'}, (r) => { chrome.tabs.getCurrent((tab) => { document.title = 'options:' + tabs.length + (tab ? ':tab' : '') + (r && r.count ? ':bg' : ''); }); }); });",
            // A popup isn't in a tab (Chrome's answer, which extensions rely on to size it).
            "popup.html": "<!doctype html><title>Popup</title><body style='width: 300px; height: 200px'>Popup<script src=popup.js></script>",
            "popup.js": "chrome.tabs.getCurrent().then((tab) => { document.title = 'popup:' + (tab ? 'tab' : 'none'); });",
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
        check("Extensions : la page d'options s'ouvre dans un onglet, accède à chrome.tabs et joint le script d'arrière-plan (globales masquées par l'extension, API absente de WebKit)",
              optionsTab?.url?.scheme == "webkit-extension" && optionsTitle.hasPrefix("options:") && optionsTitle.hasSuffix(":tab:bg"), "« \(optionsTitle) » \(optionsTab?.url?.absoluteString ?? "")")
        if let optionsTab, optionsTab.url?.scheme == "webkit-extension" { optionsTab.browser?.close(optionsTab, force: true) }

        // The action's popup, over a page: not a tab for the extension, and sized to its content.
        let under = await htmlTab("<!doctype html><title>Sous le popup</title><body>Page</body>", in: space, base: "https://example.com/popup")
        browser.window?.makeKeyAndOrderFront(nil)
        manager.performAction(context, in: browser)
        var popupTitle = ""
        for _ in 0..<40 where !popupTitle.hasPrefix("popup:") {
            await sleep(0.25)
            popupTitle = manager.action(context, in: browser)?.popupWebView?.title ?? ""
        }
        await sleep(0.5)
        let popover = manager.action(context, in: browser)?.popupPopover
        let popoverSize = popover?.contentSize ?? .zero
        check("Extensions : le popup d'action n'est pas un onglet pour l'extension (tabs.getCurrent) et prend la taille de son contenu",
              popupTitle == "popup:none" && popover?.isShown == true && popoverSize.width >= 300 && popoverSize.height >= 200,
              "« \(popupTitle) » \(NSStringFromSize(popoverSize)) affiché=\(popover?.isShown ?? false)")
        await testPopupResize(manager.action(context, in: browser), extensionID: context.uniqueIdentifier)
        manager.action(context, in: browser)?.closePopup()
        browser.close(under, force: true)

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

    /// The popup's grip, with mouse events posted to the popover: the popup grows, the page gets
    /// the new size (a popup made to fill it follows), the size is remembered; double-click: back.
    @available(macOS 15.4, *)
    private func testPopupResize(_ action: WKWebExtension.Action?, extensionID: String) async {
        guard let popover = action?.popupPopover, let popup = action?.popupWebView, let container = popup.superview,
              let grip = container.subviews.last(where: { $0 !== popup }), let window = grip.window else {
            return check("Popup d'extension : poignée de redimensionnement absente", false)
        }
        let key = ExtensionPopupSizing.key(extensionID)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let before = popover.contentSize
        let growsUp = grip.frame.minY > container.bounds.midY
        window.makeKey()   // as the user's click would
        let start = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
        func post(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) {
            // The grip reads the pointer's screen position.
            let screen = window.convertPoint(toScreen: point)
            CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y))
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        post(.leftMouseDown, start)
        await sleep(0.2)
        let end = NSPoint(x: start.x + 120, y: start.y + (growsUp ? 80 : -80))
        for i in 1...10 {
            post(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * CGFloat(i) / 10, y: start.y + (end.y - start.y) * CGFloat(i) / 10))
            await sleep(0.05)
        }
        post(.leftMouseUp, end)
        await sleep(1)
        let after = popover.contentSize
        let inner = await popup.voidCall("return [innerWidth, innerHeight];", timeout: 3) as? [Double]
        let saved = UserDefaults.standard.string(forKey: key).map(NSSizeFromString)
        check("Popup d'extension : la poignée l'agrandit, la page suit, la taille est retenue",
              after.width > before.width + 60 && after.height > before.height + 40 && inner?.first == Double(after.width) && saved == after,
              "\(NSStringFromSize(before)) → \(NSStringFromSize(after)) · page \(inner.map { "\($0)" } ?? "?") · retenue \(saved.map(NSStringFromSize) ?? "non")")

        let grip2 = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
        post(.leftMouseDown, grip2, clicks: 2)
        post(.leftMouseUp, grip2, clicks: 2)
        await sleep(1)
        check("Popup d'extension : double-clic sur la poignée, retour à sa taille",
              popover.contentSize == before && UserDefaults.standard.string(forKey: key) == nil, NSStringFromSize(popover.contentSize))
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
