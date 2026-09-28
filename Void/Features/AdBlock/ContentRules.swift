import Foundation
import WebKit

/// Compiles and installs Void's WKContentRuleLists on the shared content controller:
///  • "void-adblock": ad/tracker blocking (compiled WebKit rules, no script, applied before load)
///  • "void-hidden": the user's hidden elements (⌘⇧H), as per-site css-display-none rules.
/// Compiled lists are cached by WebKit on disk; recompilation only happens when rules change.
@MainActor
final class ContentRules {
    static let shared = ContentRules()

    private let store = WKContentRuleListStore.default()!
    private var adBlockList: WKContentRuleList?
    private var hiddenList: WKContentRuleList?
    private var ready = false
    private var waiters: [() -> Void] = []

    func start() {
        Task {
            await installAdBlock()
            await installHidden()
            markReady()
        }
        // Never hold the first page load for more than half a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.markReady() }
    }

    func whenReady(_ block: @escaping () -> Void) {
        if ready { block() } else { waiters.append(block) }
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        waiters.forEach { $0() }
        waiters = []
    }

    func reload() {
        Task { await installAdBlock() }
    }

    func reloadHidden() {
        Task { await installHidden() }
    }

    // MARK: - Ad blocking

    private func installAdBlock() async {
        let ucc = WebViewFactory.contentController
        if let adBlockList { ucc.remove(adBlockList) }
        adBlockList = nil
        guard AppSettings.shared.adBlockEnabled else { return }

        let allowlist = AppSettings.shared.adBlockAllowlist.sorted()
        let json = AdBlockList.encodedRules(allowlist: allowlist)
        let identifier = "void-adblock-\(AdBlockList.version)-\(Self.hash(json))"
        let list = await lookupOrCompile(identifier: identifier, json: json)
        if let list {
            adBlockList = list
            ucc.add(list)
        }
    }

    // MARK: - Hidden elements

    private func installHidden() async {
        let ucc = WebViewFactory.contentController
        if let hiddenList { ucc.remove(hiddenList) }
        hiddenList = nil
        let json = ElementHider.shared.encodedRules()
        guard json != "[]" else { return }
        let identifier = "void-hidden-\(Self.hash(json))"
        if let list = await lookupOrCompile(identifier: identifier, json: json) {
            hiddenList = list
            ucc.add(list)
        }
    }

    private func lookupOrCompile(identifier: String, json: String) async -> WKContentRuleList? {
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) { return cached }
        do {
            return try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
        } catch {
            NSLog("[Void] Content rule list %@ failed: %@", identifier, String(describing: error))
            return nil
        }
    }

    private static func hash(_ string: String) -> String {
        var h: UInt64 = 1469598103934665603   // FNV-1a
        for byte in string.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return String(h, radix: 36)
    }
}
