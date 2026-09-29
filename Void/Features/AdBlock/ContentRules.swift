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
    /// Bumped at each install: a compilation that finishes after a newer one started is dropped
    /// (two quick toggles would otherwise leave both lists installed, the stale one for good).
    private var adBlockGeneration = 0
    private var hiddenGeneration = 0
    #if DEBUG
    /// Identifiers of the lists on the content controller, for the self-test.
    private(set) var installedIdentifiers: Set<String> = []
    #endif

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
        adBlockGeneration &+= 1
        let generation = adBlockGeneration
        var list: WKContentRuleList?
        if AppSettings.shared.adBlockEnabled {
            let allowlist = AppSettings.shared.adBlockAllowlist
            list = await lookupOrCompile(identifier: Self.adBlockIdentifier(allowlist: allowlist),
                                         json: AdBlockList.encodedRules(allowlist: allowlist.sorted()))
            guard generation == adBlockGeneration else { return }
        }
        replace(&adBlockList, with: list)
    }

    /// The compiled list's name: a new allowlist is a new list (WebKit caches each on disk).
    static func adBlockIdentifier(allowlist: [String]) -> String {
        "void-adblock-\(AdBlockList.version)-\(hash(AdBlockList.encodedRules(allowlist: allowlist.sorted())))"
    }

    // MARK: - Hidden elements

    private func installHidden() async {
        hiddenGeneration &+= 1
        let generation = hiddenGeneration
        var list: WKContentRuleList?
        let json = ElementHider.shared.encodedRules()
        if json != "[]" {
            list = await lookupOrCompile(identifier: "void-hidden-\(Self.hash(json))", json: json)
            guard generation == hiddenGeneration else { return }
        }
        replace(&hiddenList, with: list)
    }

    /// The new list goes in before the old one comes out: no page loads unblocked in between.
    /// The controller keys lists by identifier, so an identical one is left as it is.
    private func replace(_ current: inout WKContentRuleList?, with new: WKContentRuleList?) {
        let ucc = WebViewFactory.contentController
        if let new, new.identifier != current?.identifier { ucc.add(new) }
        if let old = current, old.identifier != new?.identifier { ucc.remove(old) }
        #if DEBUG
        if let old = current { installedIdentifiers.remove(old.identifier) }
        if let new { installedIdentifiers.insert(new.identifier) }
        #endif
        current = new
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
