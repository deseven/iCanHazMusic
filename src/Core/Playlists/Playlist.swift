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
    /// Short format label (currently the upper-cased file extension).
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

/// Where an album's cover would come from. Only the decision is recorded; nothing is loaded yet.
enum AlbumCover: Equatable {
    /// An image file in the album's directory.
    case file(URL)
    /// Artwork embedded in this audio file.
    case embedded(URL)
    case none
}

struct Album {
    /// Directory all tracks of the album live in.
    let directory: URL
    let artist: String
    let title: String
    let year: String?
    let cover: AlbumCover
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
final class Playlist {
    let albums: [Album]
    let rows: [Row]
    /// Row index of the header of each album.
    let headerRow: [Int]
    /// Row indexes of the tracks of each album (always headerRow + 1 ... ).
    let trackRows: [Range<Int>]

    static let empty = Playlist(albums: [])

    var trackCount: Int { rows.count - albums.count }

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
    }

    /// A new playlist with `newAlbums` added at the end. Existing row ids stay valid.
    func appending(_ newAlbums: [Album]) -> Playlist {
        Playlist(albums: albums + newAlbums)
    }

    func track(for row: Row) -> Track? {
        guard let t = row.trackIndex else { return nil }
        return albums[row.albumIndex].tracks[t]
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
