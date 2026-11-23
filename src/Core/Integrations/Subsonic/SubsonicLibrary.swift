// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// An album with its songs, as the browse sheet and the playlist take them.
struct SubsonicAlbumContent: Equatable, Sendable {
    let album: SubsonicAlbum
    /// By disc, then by track number.
    let songs: [SubsonicSong]
}

/// Browsing the library of a server: by tags (the ID3 endpoints `getArtists`, `getArtist` and `getAlbum`), which is
/// what Navidrome and the other servers all have.
extension SubsonicConnection {
    /// How many `getAlbum` calls of an artist are out at once.
    static let albumFetchConcurrency = 4

    func artists() async throws -> [SubsonicArtist] {
        SubsonicAPI.parseArtists(try await call("getArtists"))
    }

    /// The albums of an artist, the oldest first (those without a year last), then by name.
    func albums(ofArtist artistID: String) async throws -> [SubsonicAlbum] {
        let response = try await call("getArtist", [("id", artistID)])
        guard let parsed = SubsonicAPI.parseArtist(response) else {
            throw SubsonicError(.rejected, "the server's answer has no artist")
        }
        return parsed.albums.sorted(by: Self.isAlbumOrderedBefore)
    }

    func album(_ albumID: String) async throws -> SubsonicAlbumContent {
        let response = try await call("getAlbum", [("id", albumID)])
        guard let parsed = SubsonicAPI.parseAlbum(response) else {
            throw SubsonicError(.rejected, "the server's answer has no album")
        }
        return SubsonicAlbumContent(album: parsed.album, songs: parsed.songs.sorted(by: SubsonicSong.isOrderedBefore))
    }

    /// The playlists the user can see on the server (their own and the ones others share), by name.
    func playlists() async throws -> [SubsonicPlaylist] {
        SubsonicAPI.parsePlaylists(try await call("getPlaylists"))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A playlist with its songs, in its order.
    func playlistContent(_ playlistID: String) async throws -> (playlist: SubsonicPlaylist, songs: [SubsonicSong]) {
        let response = try await call("getPlaylist", [("id", playlistID)])
        guard let playlist = SubsonicAPI.parsePlaylist(response), let songs = SubsonicAPI.parsePlaylistEntries(response) else {
            throw SubsonicError(.rejected, "the server's answer has no playlist")
        }
        return (playlist, songs)
    }

    // MARK: Changing playlists

    /// Makes a new playlist (private, as the server makes them) with these songs. Returns what the server says about it;
    /// nil from a server too old (before 1.14) to say, then the caller has to look at `playlists()`.
    func createPlaylist(name: String, songIDs: [String] = []) async throws -> SubsonicPlaylist? {
        let response = try await write("createPlaylist", [("name", name)] + songIDs.map { ("songId", $0) })
        return SubsonicAPI.parsePlaylist(response)
    }

    /// Makes the songs of the playlist exactly these, in this order (`createPlaylist` with an ID replaces the content).
    /// This is the only way to move a song.
    func replacePlaylist(_ playlistID: String, songIDs: [String]) async throws {
        _ = try await write("createPlaylist", [("playlistId", playlistID)] + songIDs.map { ("songId", $0) })
    }

    /// Renames a playlist, adds songs at its end and/or removes the songs at these places (counted from 0 in the playlist
    /// as it is before the call).
    func updatePlaylist(_ playlistID: String, name: String? = nil, adding songIDs: [String] = [],
                        removingIndexes indexes: [Int] = []) async throws {
        var params = [("playlistId", playlistID)]
        if let name { params.append(("name", name)) }
        params += songIDs.map { ("songIdToAdd", $0) }
        params += indexes.map { ("songIndexToRemove", String($0)) }
        _ = try await write("updatePlaylist", params)
    }

    func deletePlaylist(_ playlistID: String) async throws {
        _ = try await write("deletePlaylist", [("id", playlistID)])
    }

    func song(_ songID: String) async throws -> SubsonicSong {
        let response = try await call("getSong", [("id", songID)])
        guard let song = SubsonicAPI.parseSong(response) else {
            throw SubsonicError(.rejected, "the server's answer has no song")
        }
        return song
    }

    /// Every album of an artist with its songs, in the order of `albums(ofArtist:)`. The albums are asked for a few at a
    /// time; `progress` is told how many are done (and how many there are) as they come in.
    func albumContents(ofArtist artistID: String,
                       progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> [SubsonicAlbumContent] {
        let albums = try await albums(ofArtist: artistID)
        var contents = [SubsonicAlbumContent?](repeating: nil, count: albums.count)
        progress?(0, albums.count)
        var done = 0
        try await withThrowingTaskGroup(of: (Int, SubsonicAlbumContent).self) { group in
            var next = 0
            func startNext() {
                guard next < albums.count else { return }
                let index = next
                next += 1
                group.addTask { (index, try await self.album(albums[index].id)) }
            }
            for _ in 0..<min(Self.albumFetchConcurrency, albums.count) { startNext() }
            while let (index, content) = try await group.next() {
                contents[index] = content
                done += 1
                progress?(done, albums.count)
                startNext()
            }
        }
        return contents.compactMap { $0 }
    }

    private static func isAlbumOrderedBefore(_ a: SubsonicAlbum, _ b: SubsonicAlbum) -> Bool {
        let (yearA, yearB) = (a.year ?? Int.max, b.year ?? Int.max)
        if yearA != yearB { return yearA < yearB }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
