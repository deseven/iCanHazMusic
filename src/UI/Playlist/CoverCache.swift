// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// Covers for the album headers: the cached thumbnail from `CoverStore` if the album has one, else a generated
/// placeholder (gradient + first letter). Rows only ever get small, already-scaled images (the import made them);
/// full-size artwork is never decoded here.
///
/// Scrolling must never wait for a cover: `cached` answers from memory only, `load` reads and decodes off the main
/// thread (and gives up if its task is cancelled, i.e. the header was scrolled away before it was needed). Images
/// come out decoded and with their rounded corners drawn in, so showing one costs nothing more. Only the covers
/// seen last are kept (`cache`'s count limit); the others are read from the store again when they come back.
@MainActor
enum CoverCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300   // ~50 KB each, decoded
        return cache
    }()
    /// Counts `reset`s: a cover loaded before the latest one may be out of date.
    private(set) static var generation = 0
    /// How long a header has to stay rendered before its cover is read: a fast scroll mounts and drops headers
    /// within a frame or two, which then cost nothing.
    private static let loadDelay: Duration = .milliseconds(40)
    nonisolated static let cornerRadius: CGFloat = 4

    /// The cover if it is in memory (the cheap check a row's `body` may do).
    static func cached(for album: Album) -> NSImage? {
        cache.object(forKey: album.key as NSString)
    }

    /// The cover, read (or drawn) off the main thread if it isn't in memory; nil if the calling task was cancelled
    /// meanwhile.
    static func load(for album: Album) async -> NSImage? {
        if let cached = cached(for: album) { return cached }
        let generation = generation
        try? await Task.sleep(for: loadDelay)
        guard !Task.isCancelled,
              let rendered = await render(key: album.key, artist: album.artist, title: album.title) else { return nil }
        let image = NSImage(cgImage: rendered, size: NSSize(width: Layout.coverSize, height: Layout.coverSize))
        if generation == self.generation { cache.setObject(image, forKey: album.key as NSString) }
        return image
    }

    /// Forget everything, e.g. after an import, which may have added art for albums that showed a placeholder.
    static func reset() {
        cache.removeAllObjects()
        generation += 1
    }

    // MARK: Rendering (off the main thread)

    private nonisolated static func render(key: String, artist: String, title: String) async -> CGImage? {
        let data = CoverStore.shared.data(for: key)
        guard !Task.isCancelled else { return nil }
        if let data, let stored = storedImage(data) { return stored }
        return placeholder(artist: artist, title: title)
    }

    private nonisolated static func storedImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = makeContext() else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage()
    }

    private nonisolated static func placeholder(artist: String, title: String) -> CGImage? {
        guard let context = makeContext() else { return nil }
        let px = CGFloat(context.width)
        let seed = Int(truncatingIfNeeded: "\(artist)|\(title)".stableHash % 360)
        let c1 = NSColor(hue: CGFloat(seed) / 360, saturation: 0.6, brightness: 0.85, alpha: 1)
        let c2 = NSColor(hue: CGFloat((seed + 60) % 360) / 360, saturation: 0.7, brightness: 0.55, alpha: 1)
        if let gradient = CGGradient(colorsSpace: context.colorSpace, colors: [c1.cgColor, c2.cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: px, y: px), options: [])
        }

        let letter = String(title.prefix(1))
        if !letter.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: px * 0.5, weight: .bold),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.withAlphaComponent(0.85).cgColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: letter, attributes: attributes))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            context.textPosition = CGPoint(x: (px - width) / 2, y: (px - ascent - descent) / 2 + descent)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }

    /// A square bitmap of the thumbnail's size (2x the cover), clipped to the cover's rounded corners.
    private nonisolated static func makeContext() -> CGContext? {
        let px = AppConstants.coverThumbnailPixels
        guard let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let radius = cornerRadius * CGFloat(px) / Layout.coverSize
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: px, height: px),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.interpolationQuality = .high
        return context
    }
}
