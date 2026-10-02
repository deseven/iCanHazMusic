import Foundation
import ImageIO
import CoreGraphics

/// The big album art shown while playing: the original image (no downscaling to thumbnail size), only cut to
/// a centered square. Found with the same priority as the cached thumbnails (`ArtworkSource`), but looked up
/// on demand, since playback has no tag read results at hand.
enum PlaybackArtwork {
    private static let timeout: TimeInterval = 30
    /// How many files of an album are tried for embedded art before giving up on it (same as the thumbnails).
    private static let maxEmbeddedAttempts = 3
    /// Safety net against freak images; real covers are far below this.
    private static let maxPixels = 8192

    /// `embeddedFrom`: the album's files in the order they should be tried for embedded art (the playing one
    /// first). nil if the album has no usable art.
    static func load(directory: URL, embeddedFrom files: [URL]) async -> CGImage? {
        let listing = (try? await TagReader.offload(timeout: timeout) { ExternalArtwork.scan(directory: directory) }) ?? .empty

        var candidates: [AlbumArtJob.Candidate] = []
        if let name = listing.preferred {
            candidates.append(.file(directory.appendingPathComponent(name, isDirectory: false)))
        }
        candidates += files.prefix(maxEmbeddedAttempts).map { .embedded($0) }
        if let name = listing.anyImage {
            candidates.append(.file(directory.appendingPathComponent(name, isDirectory: false)))
        }

        for candidate in candidates {
            if Task.isCancelled { return nil }
            guard let data = await AlbumArtProcessor.load(candidate) else { continue }
            let image = await Task.detached(priority: .userInitiated) { square(from: data) }.value
            if let image { return image }
        }
        return nil
    }

    /// Decodes `data` at full size (honoring EXIF orientation) and cuts the centered square out of it.
    /// The result is fully decoded, so `data` isn't needed afterwards.
    static func square(from data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let side = min(image.width, image.height)
        guard image.width != image.height else { return image }
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        return image.cropping(to: crop)
    }
}
