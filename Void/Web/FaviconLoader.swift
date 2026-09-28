import AppKit
import WebKit

/// Finds the page's icon (link rel=icon, else /favicon.ico) and stores a 32 px PNG on the tab.
@MainActor
enum FaviconLoader {
    private static let session = URLSession(configuration: .ephemeral)
    private static var cache: [String: (NSImage, Data)] = [:]

    static func load(for tab: Tab) {
        guard let webView = tab.webView, let pageURL = webView.url, let host = pageURL.host() else { return }
        if let cached = cache[host] {
            if tab.faviconData != cached.1 { tab.setFavicon(cached.0, data: cached.1) }
            return
        }
        Task {
            let script = """
            const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="shortcut icon"]')];
            const score = l => { const s = parseInt((l.sizes && l.sizes.value || '').split('x')[0]) || 16; const svg = /svg/.test(l.type || l.href); return svg ? -1 : Math.abs(64 - s); };
            links.sort((a, b) => score(a) - score(b));
            return links.map(l => l.href).filter(h => /^https?:/.test(h));
            """
            var candidates = (await webView.voidCall(script) as? [String] ?? []).compactMap(URL.init(string:))
            if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(fallback) }
            for url in candidates.prefix(3) {
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                      let image = NSImage(data: data), image.isValid,
                      let png = image.voidResizedPNG(side: 32),
                      let resized = NSImage(data: png) else { continue }
                // Private windows leave no trace, not even in this in-memory cache.
                if !tab.isPrivate { cache[host] = (resized, png) }
                tab.setFavicon(resized, data: png)
                return
            }
        }
    }
}

extension NSImage {
    func voidResizedPNG(side: CGFloat) -> Data? {
        let px = Int(side)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
