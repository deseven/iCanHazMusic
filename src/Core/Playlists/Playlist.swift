import Foundation

// MARK: - Data model

struct Track {
    let url: URL
    /// Track number from the tags; `nil` if the file has none.
    let number: Int?
    let title: String
    let artist: String
    /// Seconds; `nil` if the file didn't report one.
    let duration: TimeInterval?
    /// Short format label: the upper-cased file extension until the track has been played once, then what
    /// `CodecLabel` makes of the file (e.g. "MP3 CBR 320k", "FLAC 24/96").
    let codec: String

    var durationText: String {
        guard let duration else { return "--:--" }
        let total = Int(duration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var numberText: String {
        number.map { String(format: "%02d", $0) } ?? ""
    }
}


struct Album {
    /// Directory all tracks of the album live in.
    let directory: URL
    let artist: String
    let title: String
    let year: String?
    /// The tracks have different artists (`artist` is then "Various Artists"), so rows show the artist per track.
    let hasMultipleArtists: Bool
    let tracks: [Track]
}

/// One line of the flattened playlist. `trackIndex == nil` means "album header".
///
/// The playlist is a *flat* list of rows: [header, track, track, header, track, ...].
/// Virtualisation and selection work on a single linear collection and we never nest
/// scrolling views.
struct Row: Identifiable, Hashable {
    let id: Int          // == index in Playlist.rows (the playlist is immutable)
    let albumIndex: Int
    let trackIndex: Int? // nil => header

    var isHeader: Bool { trackIndex == nil }
}

// MARK: - Playlist

/// Immutable, flattened playlist content. Knows nothing about row heights (see `PlaylistLayout`).
///
/// A *flat* playlist (`isFlat`, the "Don't group by albums" option) has no album blocks: every track is an
/// album of its own (see `AlbumBuilder`, so positions and playback work as before) and only the track rows exist.
final class Playlist {
    let albums: [Album]
    let isFlat: Bool
    let rows: [Row]
    /// Row index of the header of each album. Empty when `isFlat`.
    let headerRow: [Int]
    /// Row indexes of the tracks of each album (always headerRow + 1 ... , or the album's single row when flat).
    let trackRows: [Range<Int>]
    let trackCount: Int
    /// Set on the result of `appending`: the first row that is new (the view scrolls there).
    let appendedFromRow: Int?

    static let empty = Playlist(albums: [])

    init(albums: [Album], isFlat: Bool = false) {
        self.albums = albums
        self.isFlat = isFlat
        self.appendedFromRow = nil
        var rows: [Row] = []
        var headers: [Int] = []
        var ranges: [Range<Int>] = []
        rows.reserveCapacity(albums.reduce(0) { $0 + $1.tracks.count + (isFlat ? 0 : 1) })
        for (a, album) in albums.enumerated() {
            if !isFlat {
                headers.append(rows.count)
                rows.append(Row(id: rows.count, albumIndex: a, trackIndex: nil))
            }
            let first = rows.count
            for t in album.tracks.indices {
                rows.append(Row(id: rows.count, albumIndex: a, trackIndex: t))
            }
            ranges.append(first..<rows.count)
        }
        self.rows = rows
        self.headerRow = headers
        self.trackRows = ranges
        self.trackCount = rows.count - headers.count
    }

    /// Same rows as `other`, other albums (the structure is the same, only track values differ).
    private init(albums: [Album], sharingRowsOf other: Playlist) {
        self.albums = albums
        self.isFlat = other.isFlat
        self.rows = other.rows
        self.headerRow = other.headerRow
        self.trackRows = other.trackRows
        self.trackCount = other.trackCount
        self.appendedFromRow = nil
    }

    private init(appending base: Playlist, albums: [Album], isFlat: Bool) {
        let rebuilt = Playlist(albums: albums, isFlat: isFlat)
        self.albums = rebuilt.albums
        self.isFlat = isFlat
        self.rows = rebuilt.rows
        self.headerRow = rebuilt.headerRow
        self.trackRows = rebuilt.trackRows
        self.trackCount = rebuilt.trackCount
        self.appendedFromRow = base.rows.count
    }

    /// The tracks as flat entries, in playlist order (this is what gets stored).
    var entries: [TrackEntry] {
        albums.flatMap(\.entries)
    }

    /// A new playlist with the tracks of `newAlbums` added at the end and everything regrouped, exactly as
    /// a reload would do: an album that is already there absorbs the new tracks, so row ids can shift.
    func appending(_ newAlbums: [Album]) -> Playlist {
        let built = AlbumBuilder.build(from: entries + newAlbums.flatMap(\.entries), flat: isFlat)
        return Playlist(appending: self, albums: built, isFlat: isFlat)
    }

    /// The same tracks grouped into albums (`flat == false`) or not.
    func settingFlat(_ flat: Bool) -> Playlist {
        Playlist(albums: AlbumBuilder.build(from: entries, flat: flat), isFlat: flat)
    }

    /// Without the tracks at these positions of `entries`.
    func removing(entries removed: Set<Int>) -> Playlist {
        let kept = entries.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        return Playlist(albums: AlbumBuilder.build(from: kept, flat: isFlat), isFlat: isFlat)
    }

    /// With the tags of the files in `results` taken over (usable results only, others leave their tracks as
    /// they are), and regrouped, since new tags can move a track into another album. The duration and the format
    /// label are kept: what playback has learned about the file is better than what the tags say.
    func updatingTags(from results: [TagReadResult]) -> Playlist {
        var fresh: [String: TrackEntry] = [:]
        for result in results where AlbumBuilder.isUsable(result.status) {
            fresh[result.url.path] = TrackEntry(result: result)
        }
        let updated = entries.map { old -> TrackEntry in
            guard let new = fresh[old.path] else { return old }
            var entry = new
            entry.duration = old.duration ?? new.duration
            entry.codec = old.codec
            return entry
        }
        return Playlist(albums: AlbumBuilder.build(from: updated, flat: isFlat), isFlat: isFlat)
    }

    /// With the duration and format label of one track replaced; `nil` if there is no track `url` at that position.
    func replacingTrack(album a: Int, track t: Int, url: URL, duration: TimeInterval, codec: String) -> Playlist? {
        guard albums.indices.contains(a), albums[a].tracks.indices.contains(t), albums[a].tracks[t].url == url else {
            return nil
        }
        let old = albums[a].tracks[t]
        var tracks = albums[a].tracks
        tracks[t] = Track(url: old.url, number: old.number, title: old.title, artist: old.artist,
                          duration: duration, codec: codec)
        let album = albums[a]
        var updated = albums
        updated[a] = Album(directory: album.directory, artist: album.artist, title: album.title, year: album.year,
                           hasMultipleArtists: album.hasMultipleArtists, tracks: tracks)
        return Playlist(albums: updated, sharingRowsOf: self)
    }

    func track(for row: Row) -> Track? {
        guard let t = row.trackIndex else { return nil }
        return albums[row.albumIndex].tracks[t]
    }

    /// Position of a track in `entries`.
    func entryIndex(album a: Int, track t: Int) -> Int {
        albums[..<a].reduce(0) { $0 + $1.tracks.count } + t
    }

    /// Positions in `entries` of the tracks covered by the selection (selected album headers stand for
    /// all their tracks).
    func entryIndices(_ selection: Set<Int>) -> Set<Int> {
        var out = Set<Int>()
        for id in expandedTrackRows(selection) {
            out.insert(id - (isFlat ? 0 : rows[id].albumIndex + 1))
        }
        return out
    }

    // MARK: Selection
    //
    // Album headers and tracks are independent selectable items: the selection is just
    // a set of row ids. Selecting a header does NOT implicitly select its tracks (rewriting
    // the selection from `onChange` caused delayed selection changes, "reentrant operation"
    // warnings and scroll jumps). If "whole album" semantics are needed, resolve them at
    // *action* time (e.g. Return / drag): expand a selected header via `expandedTrackRows`.

    /// Track row ids covered by the selection, with selected headers expanded to their tracks.
    func expandedTrackRows(_ selection: Set<Int>) -> [Int] {
        var out = Set<Int>()
        for id in selection where rows.indices.contains(id) {
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
