// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - Data model

struct Track {
    /// Stable identity within the playlist (see `TrackID`).
    let id: TrackID
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

    /// The same track with another duration and format label.
    func replacing(duration: TimeInterval, codec: String) -> Track {
        Track(id: id, url: url, number: number, title: title, artist: artist, duration: duration, codec: codec)
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

    /// "12 tracks" / "1 track": the track count tag of the album block.
    var trackCountText: String {
        "\(tracks.count) \(tracks.count == 1 ? "track" : "tracks")"
    }

    /// The playing time of the album: the track durations that are known, added up; `nil` if none is.
    var totalDuration: TimeInterval? {
        let known = tracks.compactMap(\.duration)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}

/// Where a track is in a playlist: its album and its place in it. Only valid for the playlist it was taken from;
/// the stable way to refer to a track is its `TrackID`.
struct TrackPosition: Equatable {
    var album: Int
    var track: Int
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
/// Every track has a unique `TrackID`, which the playlist hands out itself: tracks that come in without one (an
/// import, a file from before IDs existed) or with one that is taken already get the next free number. Operations
/// that make a new playlist out of this one keep the IDs and the counter, so a number is never used for two tracks.
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
    /// The ID the next new track gets: greater than every ID that was ever in use in this playlist.
    let nextID: TrackID
    /// Set on the result of `appending`: the first row that is new (the view scrolls there).
    let appendedFromRow: Int?

    private let positions: [TrackID: TrackPosition]

    static let empty = Playlist(albums: [])

    /// `nextID`: the counter as stored with the playlist; it is raised above the IDs found in `albums` if needed.
    init(albums input: [Album], isFlat: Bool = false, nextID: TrackID = 1) {
        let (albums, next) = Self.assigningIDs(input, nextID: nextID)
        self.albums = albums
        self.nextID = next
        self.isFlat = isFlat
        self.appendedFromRow = nil
        var rows: [Row] = []
        var headers: [Int] = []
        var ranges: [Range<Int>] = []
        var positions: [TrackID: TrackPosition] = [:]
        let total = albums.reduce(0) { $0 + $1.tracks.count }
        rows.reserveCapacity(total + (isFlat ? 0 : albums.count))
        positions.reserveCapacity(total)
        for (a, album) in albums.enumerated() {
            if !isFlat {
                headers.append(rows.count)
                rows.append(Row(id: rows.count, albumIndex: a, trackIndex: nil))
            }
            let first = rows.count
            for (t, track) in album.tracks.enumerated() {
                rows.append(Row(id: rows.count, albumIndex: a, trackIndex: t))
                positions[track.id] = TrackPosition(album: a, track: t)
            }
            ranges.append(first..<rows.count)
        }
        self.rows = rows
        self.headerRow = headers
        self.trackRows = ranges
        self.trackCount = rows.count - headers.count
        self.positions = positions
    }

    /// Same rows as `other`, other albums (the structure is the same, only track values differ).
    private init(albums: [Album], sharingRowsOf other: Playlist) {
        self.albums = albums
        self.isFlat = other.isFlat
        self.rows = other.rows
        self.headerRow = other.headerRow
        self.trackRows = other.trackRows
        self.trackCount = other.trackCount
        self.nextID = other.nextID
        self.positions = other.positions
        self.appendedFromRow = nil
    }

    private init(appending base: Playlist, albums: [Album], isFlat: Bool) {
        let rebuilt = Playlist(albums: albums, isFlat: isFlat, nextID: base.nextID)
        self.albums = rebuilt.albums
        self.isFlat = isFlat
        self.rows = rebuilt.rows
        self.headerRow = rebuilt.headerRow
        self.trackRows = rebuilt.trackRows
        self.trackCount = rebuilt.trackCount
        self.nextID = rebuilt.nextID
        self.positions = rebuilt.positions
        self.appendedFromRow = base.rows.count
    }

    /// `albums` with every track that has no usable ID (none, or one that an earlier track has) given the next
    /// free one, and the counter raised above all IDs in use. Returns the input as it is if all is in order.
    private static func assigningIDs(_ albums: [Album], nextID: TrackID) -> ([Album], TrackID) {
        var next = max(nextID, 1)
        var seen = Set<TrackID>()
        var needsFix = false
        for track in albums.lazy.flatMap(\.tracks) {
            next = max(next, track.id &+ 1)
            if track.id <= unassignedTrackID || !seen.insert(track.id).inserted { needsFix = true }
        }
        guard needsFix else { return (albums, next) }

        seen.removeAll(keepingCapacity: true)
        let fixed = albums.map { album in
            let tracks = album.tracks.map { track -> Track in
                if track.id > unassignedTrackID, seen.insert(track.id).inserted { return track }
                defer { next += 1 }
                return Track(id: next, url: track.url, number: track.number, title: track.title,
                             artist: track.artist, duration: track.duration, codec: track.codec)
            }
            return Album(directory: album.directory, artist: album.artist, title: album.title, year: album.year,
                         hasMultipleArtists: album.hasMultipleArtists, tracks: tracks)
        }
        return (fixed, next)
    }

    /// The tracks as flat entries, in playlist order (this is what gets stored).
    var entries: [TrackEntry] {
        albums.flatMap(\.entries)
    }

    /// A new playlist with the tracks of `newAlbums` added at the end and everything regrouped, exactly as
    /// a reload would do: an album that is already there absorbs the new tracks, so row ids can shift.
    /// The new tracks get IDs.
    func appending(_ newAlbums: [Album]) -> Playlist {
        let built = AlbumBuilder.build(from: entries + newAlbums.flatMap(\.entries), flat: isFlat)
        return Playlist(appending: self, albums: built, isFlat: isFlat)
    }

    /// The same tracks grouped into albums (`flat == false`) or not.
    func settingFlat(_ flat: Bool) -> Playlist {
        Playlist(albums: AlbumBuilder.build(from: entries, flat: flat), isFlat: flat, nextID: nextID)
    }

    /// Without these tracks (IDs that aren't in the playlist are ignored).
    func removing(ids removed: Set<TrackID>) -> Playlist {
        let kept = entries.filter { !removed.contains($0.id) }
        return Playlist(albums: AlbumBuilder.build(from: kept, flat: isFlat), isFlat: isFlat, nextID: nextID)
    }

    /// With track `id` moved to place `index` among the tracks of its album (the place it has after the move).
    /// `nil` if nothing would change (no such track, the same place, a place outside the album). Albums keep
    /// their order and all IDs stay.
    func movingTrack(id: TrackID, toIndexInAlbum index: Int) -> Playlist? {
        guard let pos = positions[id], albums[pos.album].tracks.indices.contains(index), index != pos.track else { return nil }
        let album = albums[pos.album]
        var tracks = album.tracks
        tracks.insert(tracks.remove(at: pos.track), at: index)
        var updated = albums
        updated[pos.album] = Album(directory: album.directory, artist: album.artist, title: album.title,
                                   year: album.year, hasMultipleArtists: album.hasMultipleArtists, tracks: tracks)
        return Playlist(albums: updated, isFlat: isFlat, nextID: nextID)
    }

    /// With album number `album` moved to place `index` (the place it has after the move). In a flat playlist
    /// this moves a single track. `nil` if nothing would change.
    func movingAlbum(_ album: Int, to index: Int) -> Playlist? {
        guard albums.indices.contains(album), albums.indices.contains(index), album != index else { return nil }
        var updated = albums
        updated.insert(updated.remove(at: album), at: index)
        return Playlist(albums: updated, isFlat: isFlat, nextID: nextID)
    }

    /// With the tags of the files in `results` taken over (usable results only, others leave their tracks as
    /// they are), and regrouped, since new tags can move a track into another album. The ID, the duration and the
    /// format label are kept: what playback has learned about the file is better than what the tags say.
    func updatingTags(from results: [TagReadResult]) -> Playlist {
        var fresh: [String: TrackEntry] = [:]
        for result in results where AlbumBuilder.isUsable(result.status) {
            fresh[result.url.path] = TrackEntry(result: result)
        }
        let updated = entries.map { old -> TrackEntry in
            guard let new = fresh[old.path] else { return old }
            var entry = new
            entry.id = old.id
            entry.duration = old.duration ?? new.duration
            entry.codec = old.codec
            return entry
        }
        return Playlist(albums: AlbumBuilder.build(from: updated, flat: isFlat), isFlat: isFlat, nextID: nextID)
    }

    /// With the duration and format label of one track replaced; `nil` if there is no such track.
    func replacingTrack(id: TrackID, duration: TimeInterval, codec: String) -> Playlist? {
        guard let pos = positions[id] else { return nil }
        let album = albums[pos.album]
        var tracks = album.tracks
        tracks[pos.track] = tracks[pos.track].replacing(duration: duration, codec: codec)
        var updated = albums
        updated[pos.album] = Album(directory: album.directory, artist: album.artist, title: album.title,
                                   year: album.year, hasMultipleArtists: album.hasMultipleArtists, tracks: tracks)
        return Playlist(albums: updated, sharingRowsOf: self)
    }

    func track(for row: Row) -> Track? {
        guard let t = row.trackIndex else { return nil }
        return albums[row.albumIndex].tracks[t]
    }

    // MARK: Looking tracks up by ID

    /// Where the track is, or `nil` if the playlist doesn't have it (any more).
    func position(of id: TrackID) -> TrackPosition? {
        positions[id]
    }

    func track(id: TrackID) -> Track? {
        positions[id].map { albums[$0.album].tracks[$0.track] }
    }

    /// The row of the track.
    func row(of id: TrackID) -> Int? {
        positions[id].map { trackRows[$0.album].lowerBound + $0.track }
    }

    /// IDs of the tracks covered by the selection (selected album headers stand for all their tracks).
    func trackIDs(_ selection: Set<Int>) -> Set<TrackID> {
        Set(expandedTrackRows(selection).compactMap { track(for: rows[$0])?.id })
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
