import Foundation

/// Turns what the user typed in the address bar into a URL, or nil when it's a search.
enum URLResolver {
    static func url(from rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(" ") else { return nil }
        let lower = input.lowercased()

        for scheme in ["http://", "https://", "file://", "about:", "data:", "view-source:"] where lower.hasPrefix(scheme) {
            return URL(string: input)
        }
        if lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1") || lower.hasPrefix("[::1]") {
            return URL(string: "http://" + input)
        }
        // host[:port][/path] with a plausible TLD or an IPv4 address
        let hostPart = lower.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? lower
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let labels = host.split(separator: ".")
        let isIPv4 = labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
        if isIPv4 { return URL(string: "http://" + input) }
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter || $0 == "-" }) || tld.hasPrefix("xn--"),
              labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return URL(string: "https://" + input)
    }
}
