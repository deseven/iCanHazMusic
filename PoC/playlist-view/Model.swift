import AppKit

// MARK: - Data model

struct Track {
    let number: Int
    let title: String
    let duration: TimeInterval
    let codec: String

    var durationText: String {
        let total = Int(duration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct Album {
    let id: Int
    let artist: String
    let title: String
    let year: Int
    let tracks: [Track]
}

enum RowMetrics {
    static let header: CGFloat = 68
    static let track: CGFloat = 20
}

/// One line of the flattened playlist. `trackIndex == nil` means "album header".
///
/// The playlist is a *flat* list of rows: [header, track, track, header, track, ...].
/// This is the key trick: virtualisation/selection work on a single linear collection
/// and we never nest scrolling views.
struct Row: Identifiable, Hashable {
    let id: Int          // == index in Playlist.rows, stable because the PoC playlist is immutable
    let albumIndex: Int
    let trackIndex: Int? // nil => header

    var isHeader: Bool { trackIndex == nil }
}

// MARK: - Playlist

final class Playlist {
    let albums: [Album]
    let rows: [Row]
    /// Row index of the header of each album.
    let headerRow: [Int]
    /// Row indexes of the tracks of each album (always headerRow + 1 ... ).
    let trackRows: [Range<Int>]
    /// Y offset of the top of each row; has `rows.count + 1` entries (last = total height).
    /// Row heights are fixed per kind, so the exact document height is known up front.
    let rowOffsets: [CGFloat]

    var totalHeight: CGFloat { rowOffsets[rows.count] }

    init(albums: [Album]) {
        self.albums = albums
        var rows: [Row] = []
        var headers: [Int] = []
        var ranges: [Range<Int>] = []
        rows.reserveCapacity(albums.reduce(0) { $0 + $1.tracks.count + 1 })
        for (a, album) in albums.enumerated() {
            let h = rows.count
            headers.append(h)
            rows.append(Row(id: h, albumIndex: a, trackIndex: nil))
            for t in album.tracks.indices {
                rows.append(Row(id: rows.count, albumIndex: a, trackIndex: t))
            }
            ranges.append((h + 1)..<rows.count)
        }
        self.rows = rows
        self.headerRow = headers
        self.trackRows = ranges

        var offsets: [CGFloat] = []
        offsets.reserveCapacity(rows.count + 1)
        var y: CGFloat = 0
        for r in rows {
            offsets.append(y)
            y += r.isHeader ? RowMetrics.header : RowMetrics.track
        }
        offsets.append(y)
        self.rowOffsets = offsets
    }

    func height(of row: Int) -> CGFloat { rowOffsets[row + 1] - rowOffsets[row] }

    /// Index of the row containing vertical offset `y` (clamped).
    func rowIndex(atOffset y: CGFloat) -> Int {
        var lo = 0, hi = rows.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowOffsets[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Rows intersecting `[minY, maxY]`, extended by `overscan` points on both sides.
    func rowRange(minY: CGFloat, maxY: CGFloat, overscan: CGFloat) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let first = rowIndex(atOffset: max(0, minY - overscan))
        let last = rowIndex(atOffset: min(totalHeight - 1, max(0, maxY + overscan)))
        return first..<(last + 1)
    }

    var trackCount: Int { rows.count - albums.count }

    func track(for row: Row) -> Track? {
        guard let t = row.trackIndex else { return nil }
        return albums[row.albumIndex].tracks[t]
    }

    // MARK: Selection
    //
    // Album headers and tracks are independent selectable items: the selection is just
    // a set of row ids. Selecting a header does NOT implicitly select its tracks (an
    // earlier iteration did that by rewriting the selection from `onChange`, which
    // caused delayed selection changes, "reentrant operation" warnings and scroll jumps).
    // If "whole album" semantics are needed, resolve them at *action* time
    // (e.g. Return / drag): expand a selected header via `expandedTrackRows`.

    /// Track row ids covered by the selection, with selected headers expanded to their tracks.
    func expandedTrackRows(_ selection: Set<Int>) -> [Int] {
        var out = Set<Int>()
        for id in selection {
            let row = rows[id]
            if row.isHeader { out.formUnion(trackRows[row.albumIndex]) } else { out.insert(id) }
        }
        return out.sorted()
    }

    func selectedTrackCount(_ selection: Set<Int>) -> Int {
        selection.reduce(0) { $0 + (rows[$1].isHeader ? 0 : 1) }
    }

    func selectedAlbumCount(_ selection: Set<Int>) -> Int {
        selection.reduce(0) { $0 + (rows[$1].isHeader ? 1 : 0) }
    }
}

// MARK: - Fake data generator

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum FakeData {
    private static let adjectives = ["Silent", "Electric", "Broken", "Golden", "Midnight", "Crimson", "Hollow", "Distant", "Neon", "Paper", "Velvet", "Burning", "Frozen", "Lost", "Wild", "Slow"]
    private static let nouns = ["Echoes", "Machines", "Gardens", "Rivers", "Dreams", "Signals", "Shadows", "Highways", "Oceans", "Mirrors", "Engines", "Horizons", "Letters", "Towers", "Storms", "Satellites"]
    private static let names = ["The", "Aurora", "Kite", "Monolith", "Lumen", "Cassette", "Orbit", "Delta", "Harbor", "Nova", "Pilot", "Quartz", "Radio", "Sable", "Tundra", "Vega"]
    private static let codecs = ["CBR 320", "VBR V0", "CBR 192", "FLAC 16/44.1", "FLAC 24/96", "AAC 256", "ALAC 16/44.1", "OGG Q6"]

    static func makePlaylist(albumCount: Int, seed: UInt64 = 42) -> Playlist {
        var rng = SplitMix64(state: seed)
        var albums: [Album] = []
        albums.reserveCapacity(albumCount)
        for i in 0..<albumCount {
            let artist = "\(names.randomElement(using: &rng)!) \(nouns.randomElement(using: &rng)!)"
            let title = "\(adjectives.randomElement(using: &rng)!) \(nouns.randomElement(using: &rng)!)"
            let year = Int.random(in: 1965...2025, using: &rng)
            let codec = codecs.randomElement(using: &rng)!
            let trackCount = Int.random(in: 5...18, using: &rng)
            var tracks: [Track] = []
            for t in 0..<trackCount {
                let name = "\(adjectives.randomElement(using: &rng)!) \(nouns.randomElement(using: &rng)!)"
                tracks.append(Track(number: t + 1,
                                    title: name,
                                    duration: TimeInterval(Int.random(in: 90...480, using: &rng)),
                                    codec: codec))
            }
            albums.append(Album(id: i, artist: artist, title: title, year: year, tracks: tracks))
        }
        return Playlist(albums: albums)
    }
}

// MARK: - Fake cover art

/// Generates (and caches) small placeholder covers.
/// In the real app this would be an async thumbnail loader (ImageIO downsampling
/// + NSCache); the important point is that the cell only asks for an already-scaled
/// image and never decodes full-size artwork on the main thread.
enum CoverCache {
    private static let cache = NSCache<NSNumber, NSImage>()
    static let size: CGFloat = 56

    static func image(for album: Album) -> NSImage {
        let key = NSNumber(value: album.id)
        if let cached = cache.object(forKey: key) { return cached }

        let px = Int(size * 2)
        let hue1 = CGFloat((album.id &* 37) % 360) / 360
        let hue2 = CGFloat((album.id &* 37 + 60) % 360) / 360
        let c1 = NSColor(hue: hue1, saturation: 0.6, brightness: 0.85, alpha: 1)
        let c2 = NSColor(hue: hue2, saturation: 0.7, brightness: 0.55, alpha: 1)

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
        letter.draw(at: NSPoint(x: (CGFloat(px) - s.width) / 2, y: (CGFloat(px) - s.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        cache.setObject(image, forKey: key)
        return image
    }
}
