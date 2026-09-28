#if DEBUG
import AppKit
import WebKit

/// Automated Picture-in-Picture check, run against the real app code paths
/// (BrowserModel, WebHost, PiPController, FloatingPlayer). Debug builds only.
///
///   Void.app/Contents/MacOS/Void -VoidSelfTest pip [-VoidSelfTestOut /path/report.md] [-VoidSelfTestOnly html5,youtube]
///
/// Uses a throw-away space with private (in-memory) tabs; never touches the saved session.
/// Videos play at 2 % volume.
@MainActor
enum SelfTestRunner {
    static var isRequested: Bool { UserDefaults.standard.string(forKey: "VoidSelfTest") != nil }

    static func startIfRequested() {
        guard isRequested else { return }
        if UserDefaults.standard.string(forKey: "VoidSelfTest") == "features" {
            let out = UserDefaults.standard.string(forKey: "VoidSelfTestOut") ?? (NSTemporaryDirectory() + "void-features-selftest.md")
            Task {
                try? await Task.sleep(for: .seconds(2))
                await FeatureSelfTest(outputPath: out).run()
                NSApp.terminate(nil)
            }
            return
        }
        let out = UserDefaults.standard.string(forKey: "VoidSelfTestOut") ?? (NSTemporaryDirectory() + "void-pip-selftest.md")
        let only = UserDefaults.standard.string(forKey: "VoidSelfTestOnly")?.split(separator: ",").map(String.init)
        Task {
            try? await Task.sleep(for: .seconds(2))
            await PiPSelfTest(outputPath: out, only: only).run()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class PiPSelfTest {
    struct Case {
        let id: String
        let label: String
        let url: URL?
        let html: String?
    }

    struct Check {
        var name: String
        var passed: Bool
        var detail: String
    }

    struct CaseResult {
        var testCase: Case
        var checks: [Check] = []
        var log: [String] = []
    }

    private let outputPath: String
    private let only: [String]?
    private let browser = BrowserModel.shared
    private var space: Space!

    init(outputPath: String, only: [String]?) {
        self.outputPath = outputPath
        self.only = only
    }

    static let bunnyMP4 = "https://media.w3.org/2010/05/sintel/trailer.mp4"

    var cases: [Case] {
        [
            Case(id: "html5", label: "Vidéo HTML5 simple (<video> MP4)", url: nil, html: """
                <!doctype html><title>HTML5 video</title><body style="margin:0;background:#111">
                <video src="\(Self.bunnyMP4)" width="960" height="540" controls playsinline loop></video></body>
                """),
            Case(id: "disabled", label: "Vidéo HTML5 avec disablepictureinpicture (site qui refuse le PiP)", url: nil, html: """
                <!doctype html><title>PiP disabled</title><body style="margin:0;background:#111">
                <video src="\(Self.bunnyMP4)" width="960" height="540" controls playsinline loop disablepictureinpicture></video></body>
                """),
            Case(id: "native", label: "Repli natif WebKit seul (_togglePictureInPicture)", url: nil, html: """
                <!doctype html><title>Native toggle</title><body style="margin:0;background:#111">
                <video src="\(Self.bunnyMP4)" width="960" height="540" controls playsinline loop></video></body>
                """),
            Case(id: "iframe", label: "Lecteur YouTube dans une iframe sans allow=\"picture-in-picture\"", url: nil, html: """
                <!doctype html><title>Iframe embed</title><body style="margin:0;background:#111">
                <iframe src="https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ" width="960" height="540" frameborder="0"></iframe></body>
                """),
            Case(id: "youtube", label: "YouTube (page de lecture)", url: URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ"), html: nil),
            Case(id: "vimeo", label: "Vimeo (streaming HLS)", url: URL(string: "https://vimeo.com/1084537"), html: nil),
            Case(id: "dailymotion", label: "Dailymotion (streaming HLS)", url: URL(string: "https://www.dailymotion.com/video/x8lozxn"), html: nil),
            Case(id: "twitch", label: "Twitch (direct)", url: URL(string: "https://www.twitch.tv/directory/all"), html: nil),
        ].filter { only == nil || only!.contains($0.id) }
    }

    // MARK: - Run

    func run() async {
        space = browser.addSpace(name: "Self-test PiP", icon: "hammer")
        // Test-only: in every frame (consent walls often live in third-party iframes),
        // pick the privacy-preserving choice of cookie banners for a few seconds.
        WebViewFactory.contentController.addUserScript(WKUserScript(source: Self.consentAutoRefuse, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: WebViewFactory.world))
        AppSettings.shared.autoPiP = true
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        var results: [CaseResult] = []
        for testCase in cases {
            NSLog("[Void self-test] ▶ %@", testCase.id)
            let result = await runCase(testCase)
            results.append(result)
            write(results)
        }
        write(results)
        NSLog("[Void self-test] report: %@", outputPath)
    }

    private func runCase(_ testCase: Case) async -> CaseResult {
        var result = CaseResult(testCase: testCase)
        func log(_ s: String) { result.log.append(s); NSLog("[Void self-test] %@ — %@", testCase.id, s) }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { result.checks.append(Check(name: name, passed: ok, detail: detail)); log("\(ok ? "PASS" : "FAIL") \(name) \(detail)") }

        let tab = browser.openTab(url: testCase.url, in: space)
        if let html = testCase.html {
            tab.ensureWebView().loadHTMLString(html, baseURL: URL(string: "https://void-selftest.example/"))
        }
        await waitForLoad(tab, timeout: 30)
        await acceptOrRejectConsent(tab, log: log)
        await sleep(5)
        if twitchCase(testCase) { await openFirstTwitchStream(tab, log: log) }

        // Start playback.
        let playing = await startPlayback(tab, log: log)
        check("Lecture démarrée", playing, "hasVideo=\(tab.hasVideo) frames=\(tab.mediaFrames.count)")
        await snapshot(tab, name: testCase.id)
        guard playing, let webView = tab.webView else {
            log("URL finale : \(tab.webView?.url?.absoluteString ?? "-") · sélectionné=\(browser.selectedTab === tab) · fenêtre=\(tab.webView?.window != nil) · superview=\(tab.webView?.superview.map { String(describing: type(of: $0)) } ?? "nil") · onglets=\(space.tabs.count)")
            log("Vidéos : \(await callEverywhere(tab, Self.diagnostic).joined(separator: " | "))")
            browser.close(tab, force: true)
            return result
        }

        if testCase.id == "native" {
            // Only WebKit's own toggle, bypassing media.js.
            let can = WebKitSPI.canTogglePictureInPicture(webView)
            WebKitSPI.togglePictureInPicture(webView)
            await sleep(2)
            let e = pipEvidence(tab, webView)
            check("Toggle natif disponible", can, "_canTogglePictureInPicture=\(can)")
            check("PiP via toggle natif", e.active, e.detail)
            WebKitSPI.togglePictureInPicture(webView)
            await sleep(1.5)
            let off = pipEvidence(tab, webView)
            check("Sortie via toggle natif", !off.active, off.detail)
            browser.close(tab, force: true)
            return result
        }

        // 1. Manual PiP (⌘⇧P path, without the floating fallback).
        let outcome = await PiPController.shared.enter(tab, allowFloatingFallback: false)
        await sleep(1.5)
        let manual = pipEvidence(tab, webView)
        check("PiP manuel (⌘⇧P)", isEntered(outcome) && manual.active, "\(describe(outcome)) · \(manual.detail)")
        let advancingManual = await isAdvancing(tab)
        check("La vidéo continue en PiP", advancingManual.0, advancingManual.1)

        await PiPController.shared.exit(tab)
        await sleep(1.5)
        let afterExit = pipEvidence(tab, webView)
        check("Sortie du PiP", !afterExit.active, afterExit.detail)

        // 2. Automatic PiP when switching tab.
        _ = await callEverywhere(tab, "return window.__voidMedia ? await window.__voidMedia.play(0.02) : 'no-script';")
        await sleep(1.5)
        let other = browser.openTab(url: URL(string: "about:blank"), in: space)
        await sleep(3)
        let auto = pipEvidence(tab, webView)
        check("PiP automatique au changement d'onglet", auto.active, auto.detail)
        check("Vue web gardée attachée à la fenêtre", webView.window != nil, "superview=\(webView.superview.map { String(describing: type(of: $0)) } ?? "nil")")
        let advancingAuto = await isAdvancing(tab)
        check("La vidéo continue (onglet en arrière-plan)", advancingAuto.0, advancingAuto.1)

        browser.select(tab)
        await sleep(2)
        let back = pipEvidence(tab, webView)
        check("Retour sur l'onglet → sortie du PiP", !back.active, back.detail)
        browser.close(other, force: true)

        // 3. Plan B: floating window.
        _ = await callEverywhere(tab, "return window.__voidMedia ? await window.__voidMedia.play(0.02) : 'no-script';")
        FloatingPlayer.shared.open(tab)
        await sleep(2.5)
        let floatingAttached = webView.window != nil && webView.window !== browser.window
        check("Plan B : fenêtre flottante affichée", FloatingPlayer.shared.isOpen && floatingAttached, "window=\(webView.window?.className ?? "nil") level=\(webView.window?.level.rawValue ?? -1)")
        let advancingFloating = await isAdvancing(tab)
        check("Plan B : la vidéo continue", advancingFloating.0, advancingFloating.1)
        FloatingPlayer.shared.close()
        await sleep(1)
        check("Plan B : retour de la vue dans l'onglet", webView.window === browser.window, "")

        browser.close(tab, force: true)
        await sleep(1)
        return result
    }

    // MARK: - Helpers

    static let consentAutoRefuse = """
    (() => {
      const re = /^(reject all|tout refuser|refuser tout|alle ablehnen|continuer sans accepter|continue without accepting|refuser)$/i;
      const collect = (root, out) => { root.querySelectorAll('button, a, span, [role=button]').forEach(e => out.push(e));
        root.querySelectorAll('*').forEach(e => { if (e.shadowRoot) collect(e.shadowRoot, out); }); return out; };
      let n = 0;
      const t = setInterval(() => {
        const b = collect(document, []).find(x => re.test((x.innerText || x.getAttribute('aria-label') || '').trim()));
        if (b) { b.click(); clearInterval(t); }
        if (++n > 20) clearInterval(t);
      }, 750);
    })();
    """

    static let diagnostic = """
    const vs = [...document.querySelectorAll('video')];
    return location.host + ': ' + (vs.length ? vs.map(v => `ready=${v.readyState} net=${v.networkState} paused=${v.paused} err=${v.error ? v.error.code : 0} src=${(v.currentSrc || v.src || '').slice(0, 60)}`).join(' ; ') : 'no <video>')
      + ' · iframes=' + document.querySelectorAll('iframe').length + ' · title=' + document.title.slice(0, 50);
    """

    private func snapshot(_ tab: Tab, name: String) async {
        guard let webView = tab.webView else { return }
        let image: NSImage? = await withCheckedContinuation { c in
            webView.takeSnapshot(with: nil) { image, _ in c.resume(returning: image) }
        }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let path = (outputPath as NSString).deletingPathExtension + "-\(name).png"
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func twitchCase(_ c: Case) -> Bool { c.id == "twitch" }

    private func waitForLoad(_ tab: Tab, timeout: Double) async {
        let start = Date()
        await sleep(1)
        while tab.isLoading && Date().timeIntervalSince(start) < timeout { await sleep(0.3) }
    }

    /// EU consent walls (YouTube/Google, Dailymotion…): choose the privacy-preserving option.
    private func acceptOrRejectConsent(_ tab: Tab, log: (String) -> Void) async {
        guard let webView = tab.webView else { return }
        let script = """
        const re = /^(reject all|tout refuser|refuser tout|alle ablehnen|continuer sans accepter|continue without accepting|refuser)$/i;
        const collect = (root, out) => { root.querySelectorAll('button, a, span, div[role=button], [role=button], input[type=submit]').forEach(e => out.push(e));
          root.querySelectorAll('*').forEach(e => { if (e.shadowRoot) collect(e.shadowRoot, out); }); return out; };
        const buttons = collect(document, []);
        const b = buttons.find(x => x.children.length === 0 || x.tagName === 'BUTTON' ? re.test((x.innerText || x.value || x.getAttribute('aria-label') || '').trim()) : false);
        if (b) { b.click(); return 'clicked:' + (b.innerText || b.value).trim(); }
        return 'none';
        """
        for _ in 0..<2 {
            let r = await callEverywhere(tab, script)
            if r.contains(where: { $0.hasPrefix("clicked") }) {
                log("Consentement : \(r.filter { $0.hasPrefix("clicked") }.joined(separator: ","))")
                await sleep(4)
                await waitForLoad(tab, timeout: 20)
            }
            if let host = webView.url?.host(), host.hasPrefix("consent.") { await sleep(2) } else { break }
        }
    }

    private func openFirstTwitchStream(_ tab: Tab, log: (String) -> Void) async {
        guard let webView = tab.webView else { return }
        let href = await webView.voidCall("""
        const a = [...document.querySelectorAll('a[data-a-target="preview-card-image-link"], a[href^="/"][data-test-selector="TitleAndChannel"]')].find(x => x.href);
        return a ? a.href : '';
        """) as? String ?? ""
        log("Twitch : \(href.isEmpty ? "aucun live trouvé" : href)")
        if let url = URL(string: href), !href.isEmpty {
            tab.load(url)
            await waitForLoad(tab, timeout: 30)
            await sleep(8)
        }
    }

    private func startPlayback(_ tab: Tab, log: (String) -> Void) async -> Bool {
        // Embedded players only load their <video> after a click on their own play button.
        let clickPlay = """
        const b = document.querySelector('.ytp-large-play-button, .vp-controls .play, button[data-play-button], .vjs-big-play-button, .np_ButtonPlay, button[aria-label^="Play"], button[aria-label^="Lire"]');
        if (b && ![...document.querySelectorAll('video')].some(v => !v.paused)) { b.click(); return 'clicked'; }
        return 'no-button';
        """
        for attempt in 0..<8 {
            if tab.isPlayingVideo { return true }
            if attempt == 1 || attempt == 4 {
                log("clic souris natif → \(await nativeClickOnPlayer(tab))")
                await sleep(3)
                if tab.isPlayingVideo { return true }
                log("click → \(await callEverywhere(tab, clickPlay).joined(separator: ", "))")
                await sleep(2)
            }
            let results = await callEverywhere(tab, "return window.__voidMedia ? await window.__voidMedia.play(0.02) : 'no-script';")
            if attempt % 3 == 0 { log("play() → \(results.joined(separator: ", "))") }
            await sleep(2)
        }
        return tab.isPlayingVideo
    }

    /// Real mouse click (NSEvent through the window) at the centre of the largest player,
    /// exactly like a user clicking the video.
    private func nativeClickOnPlayer(_ tab: Tab) async -> String {
        guard let webView = tab.webView, let window = webView.window else { return "no-window" }
        let script = """
        const els = [...document.querySelectorAll('video, iframe')].map(e => [e, e.getBoundingClientRect()])
          .filter(([e, r]) => r.width > 150 && r.height > 90 && r.bottom > 0 && r.top < innerHeight)
          .sort((a, b) => b[1].width * b[1].height - a[1].width * a[1].height);
        if (!els.length) return null;
        const r = els[0][1];
        const top = Math.max(0, r.top), bottom = Math.min(innerHeight, r.bottom);
        return { x: r.left + r.width / 2, y: (top + bottom) / 2 };
        """
        guard let point = await webView.voidCall(script) as? [String: Double], let x = point["x"], let y = point["y"] else { return "no-player" }
        let zoom = webView.pageZoom * webView.magnification
        // WKWebView is flipped: (x, y) in CSS px from the top-left.
        let local = NSPoint(x: x * zoom, y: webView.isFlipped ? y * zoom : webView.bounds.height - y * zoom)
        let inWindow = webView.convert(local, to: nil)
        window.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
            await sleep(0.08)
        }
        return String(format: "(%.0f, %.0f)", x, y)
    }

    /// Runs a snippet in the main frame and every frame that reported media.
    @discardableResult
    private func callEverywhere(_ tab: Tab, _ script: String) async -> [String] {
        guard let webView = tab.webView else { return [] }
        var frames: [WKFrameInfo?] = [nil]
        frames += tab.mediaFrames.values.filter { !$0.frame.isMainFrame }.map { $0.frame }
        var out: [String] = []
        for frame in frames {
            let value = await webView.voidCall(script, in: frame)
            out.append((value as? String) ?? String(describing: value ?? "nil"))
        }
        return out
    }

    private func currentTime(_ tab: Tab) async -> Double {
        guard let webView = tab.webView else { return -1 }
        var best = -1.0
        var frames: [WKFrameInfo?] = [nil]
        frames += tab.mediaFrames.values.filter { !$0.frame.isMainFrame }.map { $0.frame }
        for frame in frames {
            if let t = await webView.voidCall("return window.__voidMedia ? window.__voidMedia.state().currentTime : -1;", in: frame) as? Double {
                best = max(best, t)
            }
        }
        return best
    }

    private func isAdvancing(_ tab: Tab) async -> (Bool, String) {
        let t0 = await currentTime(tab)
        await sleep(3)
        let t1 = await currentTime(tab)
        return (t1 > t0 + 1, String(format: "currentTime %.1f s → %.1f s", t0, t1))
    }

    private struct Evidence { var active: Bool; var detail: String }

    /// PiP is considered active if WebKit says so (SPI) or the page does (events),
    /// and we also look for the system PiP window (owned by PIPAgent).
    private func pipEvidence(_ tab: Tab, _ webView: WKWebView) -> Evidence {
        let spi = WebKitSPI.isPictureInPictureActive(webView)
        let windows = pipWindows()
        let active = spi || tab.isInPiP
        return Evidence(active: active, detail: "webkit=\(spi) page=\(tab.isInPiP) fenêtre-système=\(windows.isEmpty ? "non" : windows.joined(separator: "+"))")
    }

    private func pipWindows() -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard owner.localizedCaseInsensitiveContains("pip") || owner.localizedCaseInsensitiveContains("picture") else { return nil }
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            return "\(owner)(\(Int(bounds["Width"] ?? 0))×\(Int(bounds["Height"] ?? 0)))"
        }
    }

    private func isEntered(_ outcome: PiPController.Outcome) -> Bool {
        if case .entered = outcome { return true }
        return false
    }

    private func describe(_ outcome: PiPController.Outcome) -> String {
        switch outcome {
        case .entered(let method): return "méthode=\(method.rawValue)"
        case .failed(let reason): return "échec=\(reason)"
        }
    }

    // MARK: - Report

    private func write(_ results: [CaseResult]) {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let webkit = Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var md = "# Void — auto-test Picture in Picture\n\n"
        md += "- Date : \(ISO8601DateFormatter().string(from: Date()))\n- macOS : \(os)\n- WebKit : \(webkit)\n\n"
        md += "| Cas | " + (results.first?.checks.map(\.name) ?? []).joined(separator: " | ") + " |\n"
        md += "|---|" + String(repeating: "---|", count: results.first?.checks.count ?? 0) + "\n"
        for r in results {
            md += "| \(r.testCase.label) | " + r.checks.map { $0.passed ? "✅" : "❌" }.joined(separator: " | ") + " |\n"
        }
        for r in results {
            md += "\n## \(r.testCase.label)\n\n"
            for c in r.checks { md += "- \(c.passed ? "✅" : "❌") **\(c.name)** — \(c.detail)\n" }
            md += "\n<details><summary>Journal</summary>\n\n```\n" + r.log.joined(separator: "\n") + "\n```\n</details>\n"
        }
        try? md.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
}
#endif
