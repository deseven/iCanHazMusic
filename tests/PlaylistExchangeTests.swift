// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("PlaylistExchange")
    struct PlaylistExchangeTests {
        private func entry(_ path: String, artist: String = "A", title: String = "T", duration: Double? = 61.4) -> TrackEntry {
            TrackEntry(path: path, artist: artist, album: "Al", title: title, trackNumber: 1, year: nil,
                       duration: duration, codec: "MP3")
        }

        private let base = URL(fileURLWithPath: "/music/lists", isDirectory: true)

        // MARK: - Writing

        @Test("m3u/m3u8 export: header, EXTINF with rounded seconds (-1 unknown), one path per entry")
        func writesM3U() {
            let entries = [entry("/m/a.mp3"), entry("/m/b.flac", artist: "X", title: "Y", duration: nil)]
            for format in [PlaylistFormat.m3u, .m3u8] {
                let text = String(decoding: PlaylistExchange.data(for: entries, format: format), as: UTF8.self)
                #expect(text == "#EXTM3U\n#EXTINF:61,A - T\n/m/a.mp3\n#EXTINF:-1,X - Y\n/m/b.flac\n")
            }
        }

        @Test("pls export")
        func writesPLS() {
            let text = String(decoding: PlaylistExchange.data(for: [entry("/m/a.mp3")], format: .pls), as: UTF8.self)
            #expect(text == "[playlist]\nFile1=/m/a.mp3\nTitle1=A - T\nLength1=61\nNumberOfEntries=1\nVersion=2\n")
        }

        @Test("line breaks in tags can't break the file")
        func singleLineLabels() {
            let text = String(decoding: PlaylistExchange.data(for: [entry("/m/a.mp3", title: "x\ny")], format: .m3u8),
                              as: UTF8.self)
            #expect(text.components(separatedBy: "\n").count == 4)   // header, EXTINF, path, trailing empty
        }

        // MARK: - Parsing

        @Test("m3u: comments and tags are ignored, absolute/relative/file:// paths resolved, streams dropped")
        func parsesM3U() {
            let text = """
            \u{FEFF}#EXTM3U
            #EXTINF:10,Someone - Something

            /abs/one.mp3\r
            sub/two.flac
            ../up/three.mp3
            file:///with%20space/four.mp3
            http://example.com/stream.mp3
            """
            let urls = PlaylistExchange.parse(text, format: .m3u8, baseDirectory: base)
            #expect(urls.map(\.path) == ["/abs/one.mp3", "/music/lists/sub/two.flac", "/music/up/three.mp3",
                                         "/with space/four.mp3"])
        }

        @Test("pls: entries ordered by their number, titles and lengths ignored")
        func parsesPLS() {
            let text = """
            [playlist]
            NumberOfEntries=3
            File2=/b.mp3
            Title2=B
            Length2=5
            file1 = rel/a.mp3
            File10=/c.mp3
            Version=2
            """
            let urls = PlaylistExchange.parse(text, format: .pls, baseDirectory: base)
            #expect(urls.map(\.path) == ["/music/lists/rel/a.mp3", "/b.mp3", "/c.mp3"])
        }

        @Test("what is exported can be read back, in order")
        func roundTrip() {
            let entries = [entry("/m/z.mp3"), entry("/m/a b/é.flac"), entry("/m/z.mp3")]
            for format in PlaylistFormat.allCases {
                let text = String(decoding: PlaylistExchange.data(for: entries, format: format), as: UTF8.self)
                #expect(PlaylistExchange.parse(text, format: format, baseDirectory: base).map(\.path) == entries.map(\.path))
            }
        }

        // MARK: - Files

        @Test("audioFiles keeps order, drops duplicates, unsupported types and remote entries, keeps missing files")
        func audioFiles() throws {
            let dir = try TempDir()
            try dir.write("one.mp3")
            try dir.write("two.flac")
            try dir.write("lists/rel.m3u8", Data("#EXTM3U\n../two.flac\n../one.mp3\n../missing.mp3\n../notes.txt\nhttp://x/y.mp3\n../one.mp3\n".utf8))
            try dir.write("lists/second.pls", Data("[playlist]\nFile1=\(dir.path("one.mp3").path)\nFile2=\(dir.path("three.ogg").path)\n".utf8))

            let files = PlaylistExchange.audioFiles(in: [dir.path("lists/rel.m3u8"), dir.path("lists/second.pls")])
            #expect(dir.relative(files) == ["two.flac", "one.mp3", "missing.mp3", "three.ogg"])
        }

        @Test("a latin-1 encoded m3u is read too")
        func latin1() throws {
            let dir = try TempDir()
            let text = "#EXTM3U\n/m/caf\u{E9}.mp3\n"
            try dir.write("old.m3u", try #require(text.data(using: .isoLatin1)))
            #expect(PlaylistExchange.audioFiles(in: [dir.path("old.m3u")]).map(\.path) == ["/m/café.mp3"])
        }

        @Test("isPlaylistFile: by extension, regular files only")
        func detection() throws {
            let dir = try TempDir()
            try dir.write("a.M3U8")
            try dir.write("b.pls")
            try dir.write("c.mp3")
            try dir.mkdir("d.m3u")
            #expect(PlaylistExchange.isPlaylistFile(dir.path("a.M3U8")))
            #expect(PlaylistExchange.isPlaylistFile(dir.path("b.pls")))
            #expect(!PlaylistExchange.isPlaylistFile(dir.path("c.mp3")))
            #expect(!PlaylistExchange.isPlaylistFile(dir.path("d.m3u")))
            #expect(!PlaylistExchange.isPlaylistFile(dir.path("missing.m3u")))
        }

        @Test("the gatherer ignores playlist files, also inside directories")
        func gathererIgnoresPlaylists() throws {
            let dir = try TempDir()
            try dir.copy("formats/t_v23.mp3", to: "Album/01.mp3")
            try dir.write("Album/album.m3u8", Data("01.mp3\n".utf8))
            #expect(dir.relative(AudioFileGatherer.gather(from: [dir.url])) == ["Album/01.mp3"])
            #expect(AudioFileGatherer.gather(from: [dir.path("Album/album.m3u8")]).isEmpty)
        }

        // MARK: - Import

        @Test("importing a playlist keeps its order, one album per track, and reports missing files as failed")
        func importRun() async throws {
            let dir = try TempDir()
            try dir.copy("formats/t_v23.mp3", to: "b/01.mp3")
            try dir.copy("formats/t_v24.mp3", to: "a/01.mp3")
            try dir.write("list.m3u8", Data("b/01.mp3\nnope/missing.mp3\na/01.mp3\n".utf8))
            let scratch = try TempDir()
            let session = ImportSession(
                coverStore: CoverStore(url: scratch.path("covers.sqlite"), thumbnailPixels: AppConstants.coverThumbnailPixels)
            )

            let outcome = await session.run(playlists: [dir.path("list.m3u8")])

            #expect(!outcome.aborted)
            #expect(outcome.fileCount == 3)
            #expect(session.failed == 1)
            #expect(dir.relative(outcome.albums.flatMap { $0.tracks.map(\.url) }) == ["b/01.mp3", "a/01.mp3"])
            #expect(outcome.albums.map(\.tracks.count) == [1, 1])
        }
    }
}
