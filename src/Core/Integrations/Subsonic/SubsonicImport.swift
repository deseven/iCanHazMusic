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
    /// How many covers are fetched at once.
    static let coverConcurrency = 4

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

    /// Fetches the cover of every album that has one on the server and no thumbnail yet, and stores its thumbnail in the
    /// cover cache under the key of the album. A cover that can't be had is not an error (the album shows the
    /// placeholder). Returns how many were stored.
    ///
    /// `progress` is told how many covers are dealt with (stored or not) of how many are wanted, first with 0. Cancelling
    /// the task stops it.
    @MainActor
    @discardableResult
    static func cacheCovers(of albums: [Album], from connection: SubsonicConnection, into store: CoverStore = .shared,
                            progress: (@MainActor (_ done: Int, _ total: Int) -> Void)? = nil) async -> Int {
        // Albums of a playlist come one track at a time, and many of them are one album of the server.
        var seen = Set<String>()
        let wanted: [(key: String, art: String)] = albums.compactMap { album in
            guard let art = album.tracks.lazy.compactMap({ $0.subsonic?.coverArt }).first,
                  store.data(for: album.key) == nil, seen.insert(album.key).inserted else { return nil }
            return (album.key, art)
        }
        progress?(0, wanted.count)
        guard !wanted.isEmpty else { return 0 }

        // Twice the thumbnail: the thumbnail is made from what the server sends, which is a bit bigger than needed.
        let pixels = AppConstants.coverThumbnailPixels
        var stored = 0
        var index = 0
        await withTaskGroup(of: Bool.self) { group in
            func startNext() {
                guard index < wanted.count, !Task.isCancelled else { return }
                let item = wanted[index]
                index += 1
                group.addTask {
                    guard let data = try? await connection.coverArt(item.art, size: pixels * 2),
                          let thumbnail = Thumbnailer.thumbnail(from: data, pixels: pixels) else { return false }
                    store.store(thumbnail, for: item.key)
                    return true
                }
            }
            for _ in 0..<min(coverConcurrency, wanted.count) { startNext() }
            var processed = 0
            while let done = await group.next() {
                if done { stored += 1 }
                processed += 1
                progress?(processed, wanted.count)
                startNext()
            }
        }
        if stored < wanted.count, !Task.isCancelled { Log.info("subsonic: \(wanted.count - stored) of \(wanted.count) album cover(s) couldn't be had") }
        return stored
    }
}
