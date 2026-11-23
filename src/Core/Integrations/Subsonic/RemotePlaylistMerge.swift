// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Puts what a server says about a playlist (its songs, in order) into the content the app has for it.
///
/// What counts is the server; what the app adds to it is the IDs of the tracks (`TrackID`: the queue, the playing track and
/// the last played one refer to tracks by them, and have to survive a refresh), what playback learned about a file (exact
/// duration, format label) and whether the playlist is shown grouped by albums (`Playlist.isFlat`).
enum RemotePlaylistMerge {
    /// The content for `songs` (the order of the server). A song that was in `current` keeps its track's ID, duration and
    /// format label; when a song is in the playlist several times, the first copy keeps the ID of the first copy and so
    /// on. The tracks are grouped into albums like `current` was (`isFlat`), which is where the shown order can differ
    /// from the server's.
    static func merged(_ current: Playlist, songs: [SubsonicSong], connection: UUID) -> Playlist {
        var entries = SubsonicImport.entries(of: SubsonicImport.picks(ofPlaylist: songs), connection: connection)

        var before: [String: [TrackEntry]] = [:]
        for entry in current.entries {
            if let ref = entry.subsonic { before[ref.songID, default: []].append(entry) }
        }
        var used: [String: Int] = [:]
        for index in entries.indices {
            guard let ref = entries[index].subsonic else { continue }
            let copy = used[ref.songID, default: 0]
            used[ref.songID] = copy + 1
            guard let old = before[ref.songID]?[safe: copy] else { continue }
            entries[index].id = old.id
            // The same file as before: what playback measured is better than what the listing says.
            if old.subsonic?.suffix == ref.suffix {
                if let duration = old.duration { entries[index].duration = duration }
                if !old.codec.isEmpty { entries[index].codec = old.codec }
            }
        }
        return Playlist(albums: AlbumBuilder.build(from: entries, flat: current.isFlat), isFlat: current.isFlat,
                        nextID: current.nextID)
    }

    /// The two have the same tracks with the same values in the same order.
    static func isSame(_ a: Playlist, _ b: Playlist) -> Bool {
        guard a.isFlat == b.isFlat, a.trackCount == b.trackCount else { return false }
        return zip(a.entries, b.entries).allSatisfy { $0.isSame(as: $1) }
    }
}

extension TrackEntry {
    /// All that is shown or played is the same (the track of a CUE sheet is never the same as one from a server).
    func isSame(as other: TrackEntry) -> Bool {
        id == other.id && path == other.path && artist == other.artist && album == other.album && title == other.title
            && trackNumber == other.trackNumber && year == other.year && duration == other.duration && codec == other.codec
            && subsonic == other.subsonic && cue?.path == other.cue?.path
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
