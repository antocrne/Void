import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#endif

/// The few things the code shared by the Mac and iOS apps needs from AppKit or UIKit.
extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Color {
    init(platformColor: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: platformColor)
        #else
        self.init(uiColor: platformColor)
        #endif
    }
}

extension PlatformColor {
    /// A color that follows the light or dark appearance it is drawn in.
    static func voidDynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        #if os(macOS)
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        #else
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        #endif
    }
}

extension PlatformImage {
    /// The image drawn in a square of `side` pixels, as PNG. nil for data that isn't an image.
    func voidResizedPNG(side: CGFloat) -> Data? {
        #if os(macOS)
        guard isValid else { return nil }
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
        #else
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let square = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: square, format: format).pngData { _ in
            draw(in: CGRect(origin: .zero, size: square))
        }
        #endif
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
