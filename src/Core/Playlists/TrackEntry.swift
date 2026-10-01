import Foundation

/// One track as it is stored in a playlist file: flat, with everything the album grouping needs.
/// This is also the input of `AlbumBuilder`, so a fresh import and a loaded playlist go through
/// the same grouping.
///
/// Decoding is lenient: only `path` is required, everything else falls back to the values
/// the tag reader would have used. Optional values are omitted from the file when unknown.
struct TrackEntry: Codable {
    /// Full file path.
    var path: String
    var artist: String
    var album: String
    var title: String
    var trackNumber: Int?
    var year: String?
    /// Seconds.
    var duration: TimeInterval?
    /// Short format label (currently the upper-cased file extension).
    var codec: String

    var url: URL { Self.url(forPath: path) }

    /// `isDirectory:` is given on purpose: without it Foundation stats the file, which is slow on network shares.
    private static func url(forPath path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }

    init(path: String, artist: String, album: String, title: String,
         trackNumber: Int?, year: String?, duration: TimeInterval?, codec: String) {
        self.path = path
        self.artist = artist
        self.album = album
        self.title = title
        self.trackNumber = trackNumber
        self.year = year
        self.duration = duration
        self.codec = codec
    }

    /// From a tag read result (the caller has already dropped unusable ones).
    init(result r: TagReadResult) {
        self.init(
            path: r.url.path,
            artist: r.tags.artist,
            album: r.tags.album,
            // A missing title is better shown as the file name than as "Unknown Track".
            title: r.rawFields[.title] != nil ? r.tags.title : r.url.deletingPathExtension().lastPathComponent,
            trackNumber: r.tags.trackNumber,
            year: r.tags.year,
            duration: r.tags.duration,
            codec: r.url.pathExtension.uppercased()
        )
    }

    init(album: Album, track: Track) {
        self.init(
            path: track.url.path,
            artist: track.artist,
            album: album.title,
            title: track.title,
            trackNumber: track.number,
            year: album.year,
            duration: track.duration,
            codec: track.codec
        )
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        guard !path.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "empty path")
        }
        let url = Self.url(forPath: path)

        func string(_ key: CodingKeys) -> String? {
            guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
            return s
        }

        self.path = path
        artist = string(.artist) ?? TagFallback.artist
        album = string(.album) ?? TagFallback.album
        title = string(.title) ?? url.deletingPathExtension().lastPathComponent
        trackNumber = try? c.decodeIfPresent(Int.self, forKey: .trackNumber)
        year = string(.year)
        duration = try? c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        codec = string(.codec) ?? url.pathExtension.uppercased()
    }
}

extension Album {
    /// The album's tracks as flat entries.
    var entries: [TrackEntry] {
        tracks.map { TrackEntry(album: self, track: $0) }
    }
}
