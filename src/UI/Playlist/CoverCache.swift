// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// Covers for the album headers: the cached thumbnail from `CoverStore` if the album has one, else a generated
/// placeholder (gradient + first letter). Rows only ever get small, already-scaled images (the import made them);
/// full-size artwork is never decoded here. Both outcomes are kept in an `NSCache`.
enum CoverCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for album: Album) -> NSImage {
        let key = album.key as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image = storedImage(for: album) ?? placeholder(for: album)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Forget everything, e.g. after an import, which may have added art for albums that showed a placeholder.
    static func reset() {
        cache.removeAllObjects()
    }

    private static func storedImage(for album: Album) -> NSImage? {
        guard let data = CoverStore.shared.data(for: album.key), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: Layout.coverSize, height: Layout.coverSize)   // thumbnails are 2x
        return image
    }

    private static func placeholder(for album: Album) -> NSImage {
        let key = "\(album.artist)|\(album.title)" as NSString
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
        return image
    }
}
