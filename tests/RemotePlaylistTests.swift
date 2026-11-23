// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Playlist identities")
    struct PlaylistIDTests {
        @Test("a string literal is a local playlist, and the text of an ID reads back as the same ID")
        func text() {
            let connection = UUID()
            let remote = PlaylistID.remote(connection: connection, id: "pl:1/x")
            #expect(PlaylistID.local("main").text == "main")
            #expect(PlaylistID(text: "main") == "main")
            #expect(PlaylistID(text: remote.text) == remote)                       // the playlist's own ID may have : and /
            #expect(remote.text == "subsonic:\(connection.uuidString.lowercased())/pl:1/x")
            #expect(remote.connection == connection && remote.remoteID == "pl:1/x" && remote.isRemote && remote.localName == nil)
        }

        @Test("text that is not a remote playlist's is a local name")
        func notRemote() {
            for text in ["subsonic:", "subsonic:nope/x", "subsonic:\(UUID().uuidString)/", "subsonic:\(UUID().uuidString)", "rock"] {
                #expect(PlaylistID(text: text) == .local(text))
            }
        }

        @Test("a local name can't be mistaken for a remote playlist: names with a colon or a slash aren't allowed")
        func namesCannotCollide() {
            #expect(throws: PlaylistError.self) { try PlaylistStore.validate("subsonic:abc/def") }
        }
    }

    @MainActor @Suite("Remote playlist content")
    struct RemotePlaylistMergeTests {
        private let connection = UUID()

        private func song(_ id: String, album: String = "A", title: String? = nil, duration: TimeInterval? = 100,
                          suffix: String = "mp3") -> SubsonicSong {
            SubsonicSong(id: id, title: title ?? id, album: "Album \(album)", albumID: "al-\(album)", artist: "Artist", track: 1,
                         disc: nil, year: nil, duration: duration, suffix: suffix, bitRate: nil, coverArt: nil)
        }

        private func playlist(_ songs: [SubsonicSong], flat: Bool = true) -> Playlist {
            RemotePlaylistMerge.merged(Playlist(albums: [], isFlat: flat), songs: songs, connection: connection)
        }

        @Test("the tracks are those of the songs, in the order of the server, with the pseudo paths")
        func fresh() throws {
            let list = playlist([song("s1"), song("s2", album: "B"), song("s3")])
            #expect(list.songIDs == ["s1", "s2", "s3"])
            #expect(list.isFlat && list.trackCount == 3)
            let track = try #require(list.albums[1].tracks.first)
            #expect(track.subsonic?.connection == connection && track.path == "subsonic/\(connection.uuidString.lowercased()):s2")
            #expect(track.codec == "MP3" && track.duration == 100)
        }

        @Test("a song that was there keeps its track's ID, and what playback measured; a song of another suffix doesn't keep it")
        func keeping() throws {
            let first = playlist([song("s1"), song("s2")])
            let learned = try #require(first.replacingTrack(id: first.albums[0].tracks[0].id, duration: 99.5, codec: "MP3 CBR 320k"))
            let ids = learned.entries.map(\.id)

            let next = RemotePlaylistMerge.merged(learned, songs: [song("s2"), song("s1", duration: 120), song("s3")], connection: connection)
            let byID = Dictionary(uniqueKeysWithValues: next.entries.map { ($0.subsonic?.songID ?? "", $0) })
            #expect(byID["s1"]?.id == ids[0] && byID["s2"]?.id == ids[1])
            #expect(byID["s1"]?.duration == 99.5 && byID["s1"]?.codec == "MP3 CBR 320k")
            #expect(byID["s3"].map { !ids.contains($0.id) } == true)

            let converted = RemotePlaylistMerge.merged(learned, songs: [song("s1", suffix: "flac")], connection: connection)
            #expect(converted.entries[0].id == ids[0] && converted.entries[0].codec == "FLAC")
        }

        @Test("grouped by albums: the tracks of an album come together, flat: the order of the server")
        func grouping() {
            let songs = [song("a1", album: "A"), song("b1", album: "B"), song("a2", album: "A")]
            #expect(playlist(songs, flat: true).songIDs == ["a1", "b1", "a2"])
            let grouped = playlist(songs, flat: false)
            #expect(grouped.songIDs == ["a1", "a2", "b1"])
            #expect(grouped.albums.count == 2)
        }

        @Test("two contents are the same when everything shown is")
        func same() {
            let songs = [song("s1"), song("s2")]
            let list = playlist(songs)
            #expect(RemotePlaylistMerge.isSame(list, RemotePlaylistMerge.merged(list, songs: songs, connection: connection)))
            #expect(!RemotePlaylistMerge.isSame(list, RemotePlaylistMerge.merged(list, songs: [song("s1"), song("s2", title: "New")], connection: connection)))
            #expect(!RemotePlaylistMerge.isSame(list, RemotePlaylistMerge.merged(list, songs: [song("s2"), song("s1")], connection: connection)))
        }
    }

    @Suite("Remote playlist index")
    struct RemotePlaylistIndexTests {
        @Test("the index comes back as written, and what can't be read is nothing")
        func coding() throws {
            let dir = try TempDir()
            let url = dir.path("index.json")
            var info = RemotePlaylistInfo(id: "p1", name: "Road", owner: "bob", isForeign: false, isReadOnly: true,
                                          changed: "2026-03-16T03:18:41Z", songCount: 12, synced: "2026-03-16T03:18:41Z",
                                          autoDownload: true)
            try RemotePlaylistIndex.data(of: [info]).write(to: url)
            #expect(RemotePlaylistIndex.load(from: url) == [info])
            #expect(info.isUpToDate)
            info.changed = "later"
            #expect(!info.isUpToDate)

            try Data("nonsense".utf8).write(to: url)
            #expect(RemotePlaylistIndex.load(from: url).isEmpty)
            #expect(RemotePlaylistIndex.load(from: dir.path("none.json")).isEmpty)
        }

        @Test("an entry that can't be read is skipped, a newer version is not read")
        func lenient() throws {
            let dir = try TempDir()
            let url = dir.path("index.json")
            try Data(#"{"version":1,"playlists":[{"id":"p1","name":"Ok"},{"name":"no id"},{"id":7}]}"#.utf8).write(to: url)
            #expect(RemotePlaylistIndex.load(from: url).map(\.id) == ["p1"])
            try Data(#"{"version":99,"playlists":[{"id":"p1","name":"Ok"}]}"#.utf8).write(to: url)
            #expect(RemotePlaylistIndex.load(from: url).isEmpty)
        }

        @Test("a server that doesn't date its playlists is up to date once read; the order is by name, then ID; the file name is stable")
        func details() {
            var info = RemotePlaylistInfo(id: "p1", name: "A")
            #expect(!info.isUpToDate)                       // never read
            info.synced = ""
            #expect(info.isUpToDate)

            let two = RemotePlaylistInfo(id: "2", name: "Mix"), one = RemotePlaylistInfo(id: "1", name: "Mix")
            let first = RemotePlaylistInfo(id: "3", name: "Abc")
            #expect([two, one, first].sorted(by: RemotePlaylistInfo.isOrderedBefore).map(\.id) == ["3", "1", "2"])
            #expect(RemotePlaylistIndex.fileName(of: "p1") == RemotePlaylistIndex.fileName(of: "p1"))
            #expect(RemotePlaylistIndex.fileName(of: "p1") != RemotePlaylistIndex.fileName(of: "p2"))
            #expect(!RemotePlaylistIndex.fileName(of: "../x").contains("/"))
        }
    }

    @MainActor @Suite("Subsonic playlist API")
    struct SubsonicPlaylistAPITests {
        private func connection(_ server: SubsonicPlaylistServer) throws -> SubsonicConnection {
            let config = SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://music.example.org", username: "bob", password: "pw")
            let transport = server.transport
            return SubsonicConnection(config: config.normalized, transport: transport, pingTransport: transport)
        }

        @Test("a playlist is read with its owner, date and read-only flag, and what the user can change follows from them")
        func parsing() throws {
            let response = try SubsonicAPI.parse(status: 200, body: Data(#"""
            {"subsonic-response":{"status":"ok","version":"1.16.1","playlists":{"playlist":[
              {"id":"1","name":"Mine","owner":"Bob","changed":"2026-01-01T00:00:00Z","songCount":3,"duration":600},
              {"id":2,"name":"Theirs","owner":"alice","readonly":false},
              {"id":"3","name":"Smart","owner":"bob","readonly":true},
              {"id":"4","name":"No owner"}]}}}
            """#.utf8))
            let lists = SubsonicAPI.parsePlaylists(response)
            #expect(lists.map(\.id) == ["1", "2", "3", "4"])
            #expect(lists[0].changed == "2026-01-01T00:00:00Z" && lists[0].songCount == 3 && lists[0].owner == "Bob")
            #expect(lists.map { $0.isEditable(by: "bob") } == [true, false, false, true])   // not the owner, read-only, nobody's
        }

        @Test("what changes something is a POST: the credentials and the parameters are in the body, not in the URL")
        func post() async throws {
            let server = SubsonicPlaylistServer([.init(id: "p1", name: "Road", songs: ["a1", "b1"])])
            let connection = try connection(server)
            try await connection.replacePlaylist("p1", songIDs: ["b1", "a1"])
            try await connection.updatePlaylist("p1", name: "Trip", adding: ["c1"], removingIndexes: [0, 2])
            try await connection.deletePlaylist("p1")

            let requests = server.requests.filter { $0.method != "ping" }
            #expect(requests.map(\.method) == ["createPlaylist", "updatePlaylist", "deletePlaylist"])
            #expect(requests.allSatisfy { $0.isPost && $0.url.query == nil && $0.value("u") == "bob" && $0.value("t") != nil })
            #expect(requests[0].values("songId") == ["b1", "a1"])
            #expect(requests[1].value("name") == "Trip" && requests[1].values("songIdToAdd") == ["c1"]
                    && requests[1].values("songIndexToRemove") == ["0", "2"])
            #expect(requests[2].value("id") == "p1")
        }

        @Test("a song ID that has characters of a URL arrives as it is")
        func escaping() async throws {
            let server = SubsonicPlaylistServer([.init(id: "p1", name: "Road", songs: [])])
            let connection = try connection(server)
            try await connection.replacePlaylist("p1", songIDs: ["a&b=c", "d e+f", "ü/é"])
            #expect(server.requests("createPlaylist").first?.values("songId") == ["a&b=c", "d e+f", "ü/é"])
        }

        @Test("creating returns the playlist the server made; reading gives it with its songs")
        func creatingAndReading() async throws {
            let server = SubsonicPlaylistServer()
            let connection = try connection(server)
            let made = try #require(try await connection.createPlaylist(name: "Mix", songIDs: ["a1", "a2"]))
            #expect(made.name == "Mix" && made.owner == "bob")
            let read = try await connection.playlistContent(made.id)
            #expect(read.songs.map(\.id) == ["a1", "a2"] && read.playlist.changed == made.changed)
            #expect(try await connection.playlists().map(\.name) == ["Mix"])
        }

        @Test("a playlist that isn't there is a not found")
        func missing() async throws {
            let connection = try connection(SubsonicPlaylistServer())
            await #expect(throws: SubsonicError.self) { _ = try await connection.playlistContent("nope") }
        }
    }

    @Suite("Subsonic downloads of removed playlists")
    struct SubsonicPlaylistFilesTests {
        private static let connection = UUID()

        private func ref(_ song: String) -> SubsonicRef {
            SubsonicRef(connection: Self.connection, songID: song, suffix: "flac")
        }

        private func make(_ dir: TempDir, songs: [String]) throws -> (SubsonicDownloads, URL) {
            let root = dir.path("subsonic")
            let downloads = root.appendingPathComponent(Self.connection.uuidString).appendingPathComponent("downloads")
            for song in songs {
                try dir.write("subsonic/\(Self.connection.uuidString)/downloads/\(SubsonicDownloads.fileName(of: ref(song)))", Data("x".utf8))
            }
            try dir.write("subsonic/\(Self.connection.uuidString)/playlists/index.json", Data("{}".utf8))
            let provider = FakeDownloadProvider()
            return (SubsonicDownloads(directory: root, provider: provider, gigabyte: 10), downloads)
        }

        @Test("the files of these songs are deleted, the others stay, and the cached playlists are not touched")
        func removing() throws {
            let dir = try TempDir()
            let (downloads, directory) = try make(dir, songs: ["a", "b", "c"])
            #expect(downloads.removeFiles(ofSongs: [ref("a"), ref("c"), ref("never-downloaded")]) == 2)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            #expect(left == [SubsonicDownloads.fileName(of: ref("b"))])
            #expect(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("playlists/index.json").path))
        }

        @Test("quitting with no cache deletes the downloads but keeps the cached playlists")
        func quitting() throws {
            let dir = try TempDir()
            let (downloads, directory) = try make(dir, songs: ["a"])
            downloads.setCachePolicies([Self.connection: .off])
            downloads.cleanUpAtQuit()
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            #expect(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("playlists/index.json").path))
        }

        @Test("a connection that was removed loses everything, the playlists too")
        func removedConnection() throws {
            let dir = try TempDir()
            let (downloads, directory) = try make(dir, songs: ["a"])
            downloads.removeCache(of: Self.connection)
            #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
        }
    }
}
