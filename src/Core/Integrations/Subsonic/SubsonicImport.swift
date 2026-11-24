// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A song picked for the playlist, with the album of the server it is on.
struct SubsonicPick: Equatable, Sendable {
    let album: SubsonicAlbum
    let song: SubsonicSong
}

/// Turns what the server says about songs into playlist content: the tags come from the API (nothing is read from
/// files, there are none), the tracks are like any other afterwards, with the pseudo paths of `SubsonicRef`.
enum SubsonicImport {
    /// One entry per pick, in the order given.
    static func entries(of picks: [SubsonicPick], connection: UUID) -> [TrackEntry] {
        picks.map { pick in
            let song = pick.song
            let suffix = song.suffix ?? ""
            let ref = SubsonicRef(connection: connection, songID: song.id, suffix: suffix,
                                  albumID: song.albumID ?? pick.album.id, coverArt: song.coverArt ?? pick.album.coverArt)
            return TrackEntry(
                path: ref.path,
                artist: song.artist,
                album: song.album.isEmpty ? pick.album.name : song.album,
                title: song.title,
                trackNumber: song.track,
                year: (song.year ?? pick.album.year).map(String.init),
                duration: song.duration,
                codec: suffix.uppercased(),
                subsonic: ref
            )
        }
    }

    /// The albums of the playlist the picks make (the tracks of one album of the server together). `flat`: every track
    /// an album of its own, which keeps the order as it is.
    static func albums(of picks: [SubsonicPick], connection: UUID, flat: Bool = false) -> [Album] {
        AlbumBuilder.build(from: entries(of: picks, connection: connection), flat: flat)
    }

    /// The songs of a playlist of the server as picks, in the order of the playlist. A song knows its album's name, year
    /// and cover itself; the rest of what the album of a pick is for comes from the song.
    static func picks(ofPlaylist songs: [SubsonicSong]) -> [SubsonicPick] {
        songs.map { song in
            let album = SubsonicAlbum(id: song.albumID ?? song.id, name: song.album, artist: song.artist, year: song.year,
                                      songCount: nil, coverArt: song.coverArt)
            return SubsonicPick(album: album, song: song)
        }
    }
}
