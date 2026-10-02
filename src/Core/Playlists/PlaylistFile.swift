import Foundation

/// The on-disk representation of a playlist (`playlists/{name}.json`):
///
/// ```json
/// {
///   "version": 1,
///   "is_flat": false,
///   "next_id": 1043,
///   "last_played": 42,
///   "tracks": [
///     {"id": 42, "path": "/Music/A/B/01.flac", "artist": "A", "album": "B", "title": "T",
///      "trackNumber": 1, "year": "2019", "duration": 215.4, "codec": "FLAC"}
///   ]
/// }
/// ```
///
/// `tracks` is flat and in playlist order; albums are rebuilt on load (see `AlbumBuilder`).
/// `is_flat`: the playlist isn't grouped into albums (missing = false).
/// `id` (see `TrackID`) identifies a track in its playlist; `next_id` is the number the next new track gets, so a
/// number is never used twice. Files from before IDs existed have neither: the playlist numbers the tracks on load.
/// `last_played`: the ID of the track that was started last (missing = none, or one that isn't in `tracks` is ignored).
/// Album art isn't stored. A file without `version` (the former empty `{}`) is read as version 0, an empty playlist.
struct PlaylistFile: Codable {
    static let currentVersion = 1

    var version = PlaylistFile.currentVersion
    var tracks: [TrackEntry] = []
    var isFlat = false
    var nextID: TrackID = 1
    var lastPlayed: TrackID?
    /// Entries that were dropped while decoding (not written).
    private(set) var skipped = 0

    private enum CodingKeys: String, CodingKey {
        case version, tracks
        case isFlat = "is_flat"
        case nextID = "next_id"
        case lastPlayed = "last_played"
    }

    init(tracks: [TrackEntry], isFlat: Bool = false, nextID: TrackID = 1, lastPlayed: TrackID? = nil) {
        self.tracks = tracks
        self.isFlat = isFlat
        self.nextID = nextID
        self.lastPlayed = lastPlayed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        isFlat = (try? c.decodeIfPresent(Bool.self, forKey: .isFlat)) ?? false
        nextID = (try? c.decodeIfPresent(TrackID.self, forKey: .nextID)) ?? 1
        lastPlayed = try? c.decodeIfPresent(TrackID.self, forKey: .lastPlayed)
        let entries = try c.decodeIfPresent([Lossy<TrackEntry>].self, forKey: .tracks) ?? []
        tracks = entries.compactMap(\.value)
        skipped = entries.count - tracks.count
    }

    /// Decodes one array element without letting a bad entry fail the whole playlist.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    // MARK: - Reading and writing

    enum LoadResult {
        /// `lastPlayed` is only given if the playlist has that track.
        case loaded(Playlist, lastPlayed: TrackID?)
        /// There is no such file (e.g. deleted behind our back).
        case missing
        /// Unreadable, not valid JSON, or written by a newer version of the app.
        case invalid(String)
    }

    /// Blocking: reads, decodes and groups into albums. Meant to run off the main thread.
    static func load(from url: URL) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .invalid(error.localizedDescription)
        }

        let file: PlaylistFile
        do {
            file = try JSONDecoder().decode(PlaylistFile.self, from: data)
        } catch {
            return .invalid("not a valid playlist file: \(error.localizedDescription)")
        }
        guard file.version <= currentVersion else {
            return .invalid("file version \(file.version) is newer than the supported \(currentVersion)")
        }

        if file.skipped > 0 {
            Log.error("\(url.lastPathComponent): skipped \(file.skipped) entries without a usable path")
        }
        let playlist = Playlist(albums: AlbumBuilder.build(from: file.tracks, flat: file.isFlat),
                                isFlat: file.isFlat, nextID: file.nextID)
        return .loaded(playlist, lastPlayed: file.lastPlayed.flatMap { playlist.position(of: $0) == nil ? nil : $0 })
    }

    /// Blocking: atomic replace of the whole file. Meant to run off the main thread.
    static func write(_ playlist: Playlist, lastPlayed: TrackID? = nil, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(PlaylistFile(tracks: playlist.entries, isFlat: playlist.isFlat,
                                                   nextID: playlist.nextID, lastPlayed: lastPlayed))
        try data.write(to: url, options: .atomic)
    }

    static let emptyData: Data = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(PlaylistFile(tracks: []))) ?? Data("{}".utf8)
    }()
}
