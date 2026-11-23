// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Subsonic tracks in playlists")
    struct SubsonicTracksTests {
        private let connection = UUID(uuidString: "0F6C3A3E-52E8-4F1B-9C9C-6A1E3B8D7A11")!

        private func ref(_ song: String = "song-1", album: String? = "al-1") -> SubsonicRef {
            SubsonicRef(connection: connection, songID: song, suffix: "flac", albumID: album, coverArt: "al-1")
        }

        private func entry(_ song: String, title: String = "T", album: String = "Album", albumID: String? = "al-1") -> TrackEntry {
            TrackEntry(path: ref(song).path, artist: "Artist", album: album, title: title, trackNumber: 1, year: "1999",
                       duration: 200, codec: "FLAC", subsonic: ref(song, album: albumID))
        }

        // MARK: SubsonicRef

        @Test("the pseudo path names the connection and the song, whatever the song ID looks like")
        func path() throws {
            #expect(ref().path == "subsonic/0f6c3a3e-52e8-4f1b-9c9c-6a1e3b8d7a11:song-1")
            for id in ["x", "tr-123", "a:b:c", "with space", "slash/in/it", "ünï", "q?x#y"] {
                let parsed = try #require(SubsonicRef.parse(path: ref(id).path))
                #expect(parsed.connection == connection && parsed.songID == id)
            }
            #expect(SubsonicRef.parse(path: "/Users/me/Music/a.flac") == nil)
            #expect(SubsonicRef.parse(path: "/Users/me/subsonic/x:y") == nil)
            #expect(SubsonicRef.parse(path: "subsonic/not-a-uuid:song") == nil)
            #expect(SubsonicRef.parse(path: "subsonic/\(connection.uuidString):") == nil)
        }

        @Test("what the engine plays is a URL that carries the connection, the song and the suffix")
        func url() throws {
            for id in ["x", "a:b", "with space", "slash/in/it", "ünï", "q?x#y", "100%"] {
                let url = SubsonicRef(connection: connection, songID: id, suffix: "mp3").url
                #expect(!url.isFileURL && url.scheme == "subsonic")
                let back = try #require(url.subsonicRef)
                #expect(back.connection == connection && back.songID == id && back.suffix == "mp3", "\(id): \(url)")
            }
            #expect(ref().url == ref().url)
            #expect(ref("a").url != ref("b").url)
            #expect(URL(fileURLWithPath: "/tmp/a.flac").subsonicRef == nil)
            #expect(URL(string: "https://example.org/x")!.subsonicRef == nil)
        }

        @Test("the albums of two connections, or two albums, are different places")
        func albums() {
            let other = SubsonicRef(connection: UUID(), songID: "song-1", suffix: "flac", albumID: "al-1")
            #expect(ref().albumURL != other.albumURL)
            #expect(ref(album: "al-1").albumURL != ref(album: "al-2").albumURL)
            #expect(AlbumKey.make(directory: ref().albumURL, title: "A") != AlbumKey.make(directory: other.albumURL, title: "A"))
        }

        // MARK: TrackEntry

        @Test("an entry is stored with its pseudo path and an object for the rest, and comes back the same")
        func coding() throws {
            let original = entry("song-1")
            let data = try JSONEncoder().encode(original)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["path"] as? String == ref().path)
            let object = try #require(json["subsonic"] as? [String: Any])
            #expect(object["album_id"] as? String == "al-1" && object["cover_art"] as? String == "al-1" && object["suffix"] as? String == "flac")

            let decoded = try JSONDecoder().decode(TrackEntry.self, from: data)
            #expect(decoded.subsonic == ref())
            #expect(decoded.path == original.path && decoded.title == "T" && decoded.codec == "FLAC")
            #expect(decoded.url == ref().url)
            #expect(decoded.directory == ref().albumURL)
        }

        @Test("the path alone is enough to read an entry")
        func pathOnly() throws {
            let json = #"{"id": 3, "path": "\#(ref("s9").path)", "title": "Song"}"#
            let decoded = try JSONDecoder().decode(TrackEntry.self, from: Data(json.utf8))
            #expect(decoded.subsonic?.connection == connection && decoded.subsonic?.songID == "s9")
            #expect(decoded.subsonic?.albumID == nil && decoded.subsonic?.suffix == "")
            #expect(decoded.id == 3 && decoded.cue == nil)
        }

        @Test("a track without a codec gets the suffix of the song, not a made up extension")
        func codec() throws {
            let json = #"{"path": "\#(ref("s9").path)", "subsonic": {"suffix": "ogg"}}"#
            #expect(try JSONDecoder().decode(TrackEntry.self, from: Data(json.utf8)).codec == "OGG")
        }

        @Test("a broken subsonic object only costs what was in it")
        func brokenObject() throws {
            let json = #"{"path": "\#(ref("s9").path)", "subsonic": 5}"#
            let decoded = try JSONDecoder().decode(TrackEntry.self, from: Data(json.utf8))
            #expect(decoded.subsonic?.songID == "s9" && decoded.subsonic?.albumID == nil)
        }

        // MARK: Albums

        @Test("tracks are grouped by the album of the server, in the order they come")
        func grouping() {
            let albums = AlbumBuilder.build(from: [
                entry("a1", album: "First", albumID: "al-1"),
                entry("b1", album: "Second", albumID: "al-2"),
                entry("a2", album: "First", albumID: "al-1"),
            ])
            #expect(albums.map(\.title) == ["First", "Second"])
            #expect(albums[0].tracks.map(\.subsonic?.songID) == ["a1", "a2"])
            #expect(albums[0].directory == ref(album: "al-1").albumURL)
        }

        @Test("a track keeps what makes it a Subsonic track through everything that happens to a playlist")
        func track() throws {
            let albums = AlbumBuilder.build(from: [entry("a1"), entry("a2")])
            let playlist = Playlist(albums: albums)
            let track = try #require(playlist.track(for: playlist.rows[1]))
            #expect(track.subsonic == ref("a1"))
            #expect(track.path == ref("a1").path)
            #expect(track.source == PlaybackSource(url: ref("a1").url))
            #expect(!track.canReveal)
            #expect(track.replacing(duration: 10, codec: "FLAC 24/96").subsonic == ref("a1"))

            // Back into entries, as the playlist file is written.
            let entries = playlist.entries
            #expect(entries.map(\.path) == [ref("a1").path, ref("a2").path])
            #expect(entries.allSatisfy { $0.subsonic != nil })

            let removed = playlist.removing(ids: [track.id])
            #expect(removed.trackCount == 1)
            #expect(removed.track(for: removed.rows[1])?.subsonic == ref("a2"))
        }

        @Test("a track with a file is revealed in Finder, one from a server is not")
        func reveal() {
            let local = Track(id: 1, url: URL(fileURLWithPath: "/tmp/a.flac"), number: 1, title: "t", artist: "a", duration: 1, codec: "FLAC")
            #expect(local.canReveal)
        }

        // MARK: Export, waveform

        @Test("tracks of a server are not exported to M3U or PLS, and are counted as skipped")
        func export() {
            let local = TrackEntry(path: "/tmp/a.flac", artist: "A", album: "B", title: "T", trackNumber: 1, year: nil,
                                   duration: 10, codec: "FLAC")
            for format in PlaylistFormat.allCases {
                let result = PlaylistExchange.export([local, entry("s1"), entry("s2")], format: format)
                let text = String(decoding: result.data, as: UTF8.self)
                #expect(result.skipped == 2)
                #expect(text.contains("/tmp/a.flac") && !text.contains("subsonic"))
            }
        }

        @Test("the waveform of a song is stored under the song, with no file to examine")
        func waveformKey() throws {
            let a = try #require(WaveformKey.make(source: PlaybackSource(url: ref("s1").url)))
            let again = try #require(WaveformKey.make(source: PlaybackSource(url: ref("s1", album: nil).url)))
            let other = try #require(WaveformKey.make(source: PlaybackSource(url: ref("s2").url)))
            #expect(a == again && a != other)
        }

        @Test("a source on a server is logged without credentials")
        func logPath() {
            let source = PlaybackSource(url: ref("s1").url)
            #expect(source.logPath.hasPrefix("subsonic://"))
            #expect(PlaybackSource(url: URL(fileURLWithPath: "/tmp/a.flac")).logPath == "/tmp/a.flac")
        }
    }
}
