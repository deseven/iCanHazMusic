import Foundation

/// Canonical tag fields we care about. Every backend maps its native key names onto these.
public enum TagField: String, CaseIterable, Sendable {
    case title, artist, albumArtist, performer, band, discogsArtist, composer
    case album, year, track
}

/// Values shown when a tag is missing / unreadable.
public enum TagFallback {
    public static let artist = "Unknown Artist"
    public static let title = "Unknown Track"
    public static let album = "Unknown Album"
}

/// Final, display-ready tags. `title`/`artist`/`album` are never empty (fallbacks applied).
public struct TrackTags: Sendable, Equatable {
    public var title: String = TagFallback.title
    public var artist: String = TagFallback.artist
    public var album: String = TagFallback.album
    public var year: String?
    public var trackNumber: Int?
    /// Seconds. From AudioFile ("approximate duration") or AVFoundation, whichever backend ran.
    public var duration: TimeInterval?

    public init() {}
}

public enum TagReadStatus: Sendable, Equatable {
    /// title, artist and album were all found.
    case complete
    /// Some of title/artist/album were missing and replaced by fallbacks (names listed).
    case partial(fallbacks: [String])
    /// File was readable but has no title/artist/album at all.
    case noTags
    /// File could not be read (unsupported, corrupt, I/O error, timeout). Reason attached.
    case failed(String)

    public var isFailure: Bool { if case .failed = self { true } else { false } }
}

public struct TagReadResult: Sendable, Identifiable {
    /// Index of the file in the input array.
    public let id: Int
    public let url: URL
    public let tags: TrackTags
    public let status: TagReadStatus
    /// Which backends contributed, e.g. ["AudioFile", "AVFoundation"].
    public let sources: [String]
    /// Wall-clock time spent on this file.
    public let elapsed: TimeInterval
    /// Raw (post-key-mapping, pre-fallback) values. Useful for diagnostics.
    public let rawFields: [TagField: String]
    /// Detected album-art source (`.none` for failed files or when artwork detection is off).
    public let artwork: ArtworkSource
}

public enum TagReadError: LocalizedError, Sendable {
    case unreadable(String)
    case timeout(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let s): s
        case .timeout(let t): "timed out after \(Int(t)) s"
        }
    }
}
