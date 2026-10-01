import Foundation

/// The on-disk representation of a playlist (`playlists/{name}.json`):
///
/// ```json
/// {
///   "version": 1,
///   "tracks": [
///     {"path": "/Music/A/B/01.flac", "artist": "A", "album": "B", "title": "T",
///      "trackNumber": 1, "year": "2019", "duration": 215.4, "codec": "FLAC"}
///   ]
/// }
/// ```
///
/// `tracks` is flat and in playlist order; albums are rebuilt on load (see `AlbumBuilder`).
/// Album art isn't stored. A file without `version` (the former empty `{}`) is read as version 0, an empty playlist.
struct PlaylistFile: Codable {
    static let currentVersion = 1

    var version = PlaylistFile.currentVersion
    var tracks: [TrackEntry] = []
    /// Entries that were dropped while decoding (not written).
    private(set) var skipped = 0

    private enum CodingKeys: String, CodingKey {
        case version, tracks
    }

    init(tracks: [TrackEntry]) {
        self.tracks = tracks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
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
        case loaded(Playlist)
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
        return .loaded(Playlist(albums: AlbumBuilder.build(from: file.tracks)))
    }

    /// Blocking: atomic replace of the whole file. Meant to run off the main thread.
    static func write(_ playlist: Playlist, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(PlaylistFile(tracks: playlist.entries))
        try data.write(to: url, options: .atomic)
    }

    static let emptyData: Data = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(PlaylistFile(tracks: []))) ?? Data("{}".utf8)
    }()
}
