import AppKit

/// Generates (and caches) small placeholder covers.
/// In the real app this will be an async thumbnail loader (ImageIO downsampling + NSCache);
/// the important point is that a row only asks for an already-scaled image and never
/// decodes full-size artwork on the main thread.
enum CoverCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for album: Album) -> NSImage {
        let key = "\(album.artist)|\(album.title)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let size = Layout.coverSize
        let px = Int(size * 2)
        let seed = Int(truncatingIfNeeded: (key as String).stableHash % 360)
        let c1 = NSColor(hue: CGFloat(seed) / 360, saturation: 0.6, brightness: 0.85, alpha: 1)
        let c2 = NSColor(hue: CGFloat((seed + 60) % 360) / 360, saturation: 0.7, brightness: 0.55, alpha: 1)

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: c1, ending: c2)?.draw(in: NSRect(x: 0, y: 0, width: px, height: px), angle: 45)
        let letter = String(album.title.prefix(1)) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: CGFloat(px) * 0.5, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let s = letter.size(withAttributes: attrs)
        letter.draw(at: NSPoint(x: (CGFloat(px) - s.width) / 2, y: (CGFloat(px) - s.height) / 2),
                    withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        cache.setObject(image, forKey: key)
        return image
    }
}
