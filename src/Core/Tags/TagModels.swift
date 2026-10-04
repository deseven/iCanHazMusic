import Foundation

/// Canonical tag fields we care about. Every backend maps its native key names onto these.
enum TagField: String, CaseIterable, Sendable {
    case title, artist, albumArtist, performer, band, discogsArtist, composer
    case album, year, track
    /// Unsynchronised or LRC lyrics (ID3 `USLT`, Vorbis `LYRICS`, MP4 `©lyr`, ...). Can be long.
    case lyrics
}

/// Values shown when a tag is missing / unreadable.
enum TagFallback {
    static let artist = "Unknown Artist"
    static let title = "Unknown Track"
    static let album = "Unknown Album"

    /// A track that has a real artist and title, i.e. one that something outside (Last.fm, LRCLIB) can be asked about.
    static func isIdentified(artist: String, title: String) -> Bool {
        artist != Self.artist && title != Self.title
    }
}

/// Final, display-ready tags. `title`/`artist`/`album` are never empty (fallbacks applied).
struct TrackTags: Sendable, Equatable {
    var title: String = TagFallback.title
    var artist: String = TagFallback.artist
    var album: String = TagFallback.album
    var year: String?
    var trackNumber: Int?
    /// Seconds. From AudioFile ("approximate duration") or AVFoundation, whichever backend ran.
    var duration: TimeInterval?
    /// The lyrics embedded in the file (line breaks as `\n`), nil if it has none.
    var lyrics: String?

    init() {}
}

enum TagReadStatus: Sendable, Equatable {
    /// title, artist and album were all found.
    case complete
    /// Some of title/artist/album were missing and replaced by fallbacks (names listed).
    case partial(fallbacks: [String])
    /// File was readable but has no title/artist/album at all.
    case noTags
    /// File could not be read (unsupported, corrupt, I/O error, timeout). Reason attached.
    case failed(String)

    var isFailure: Bool { if case .failed = self { true } else { false } }
}

struct TagReadResult: Sendable, Identifiable {
    /// Index of the file in the input array.
    let id: Int
    let url: URL
    let tags: TrackTags
    let status: TagReadStatus
    /// Which backends contributed, e.g. ["AudioFile", "AVFoundation"].
    let sources: [String]
    /// Wall-clock time spent on this file.
    let elapsed: TimeInterval
    /// Raw (post-key-mapping, pre-fallback) values. Useful for diagnostics.
    let rawFields: [TagField: String]
    /// Detected album-art source (`.none` for failed files or when artwork detection is off).
    let artwork: ArtworkSource
}

enum TagReadError: LocalizedError, Sendable {
    case unreadable(String)
    case timeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .unreadable(let s): s
        case .timeout(let t): "timed out after \(Int(t)) s"
        }
    }
}
