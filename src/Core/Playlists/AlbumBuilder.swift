// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What makes two files one album: the same album tag (case-insensitive) in the same directory.
/// Also the key of the album's cover in the cover cache.
enum AlbumKey {
    static func make(directory: URL, title: String) -> String {
        // Unit separator: can't be in an album name for real, and (unlike NUL) survives being a SQLite text key.
        directory.path + "\u{1F}" + title.lowercased()
    }
}

extension Album {
    var key: String { AlbumKey.make(directory: directory, title: title) }
}

/// Groups flat track entries into album blocks. Used for both fresh imports and loaded playlists.
///
/// Files belong to the same album only if they have the same album tag *and* live in the same
/// directory; the same album name in two directories gives two blocks. Blocks keep the order in
/// which their first file appears in the input, files inside a block keep the input order.
enum AlbumBuilder {
    static let variousArtists = "Various Artists"

    /// Rows with `.failed` / `.noTags` are skipped. `results` must already be in playlist order.
    static func build(from results: [TagReadResult], flat: Bool = false) -> [Album] {
        build(from: results.filter { isUsable($0.status) }.map(TrackEntry.init(result:)), flat: flat)
    }

    /// `entries` must already be in playlist order. `flat`: no grouping, every entry is an album of its own
    /// (the playlist shows no album blocks then, but positions and playback still work on albums).
    static func build(from entries: [TrackEntry], flat: Bool = false) -> [Album] {
        if flat {
            return entries.map { makeAlbum(directory: $0.url.deletingLastPathComponent(), entries: [$0]) }
        }
        struct Group {
            var directory: URL
            var entries: [TrackEntry] = []
        }
        var groups: [Group] = []
        var indexByKey: [String: Int] = [:]

        for entry in entries {
            let directory = entry.url.deletingLastPathComponent()
            let key = AlbumKey.make(directory: directory, title: entry.album)
            if let i = indexByKey[key] {
                groups[i].entries.append(entry)
            } else {
                indexByKey[key] = groups.count
                groups.append(Group(directory: directory, entries: [entry]))
            }
        }
        return groups.map { makeAlbum(directory: $0.directory, entries: $0.entries) }
    }

    static func isUsable(_ status: TagReadStatus) -> Bool {
        switch status {
        case .complete, .partial: true
        case .noTags, .failed: false
        }
    }

    private static func makeAlbum(directory: URL, entries: [TrackEntry]) -> Album {
        let artists = Set(entries.map(\.artist))
        let multipleArtists = artists.count > 1
        let tracks = entries.map { e in
            Track(
                id: e.id,
                url: e.url,
                number: e.trackNumber,
                title: e.title,
                artist: e.artist,
                duration: e.duration,
                codec: e.codec
            )
        }
        return Album(
            directory: directory,
            artist: multipleArtists ? variousArtists : entries[0].artist,
            title: entries[0].album,
            year: entries.lazy.compactMap(\.year).first,
            hasMultipleArtists: multipleArtists,
            tracks: tracks
        )
    }
}
