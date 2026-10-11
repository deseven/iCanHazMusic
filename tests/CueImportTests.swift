// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// Adding CUE sheets: finding them, leaving out the files they name, reading the tracks and reloading them.
    @MainActor @Suite("CUE import")
    struct CueImportTests {
        /// `a.flac` is 3.1 s long (136 710 frames at 44.1 kHz); 75 CUE frames are 1 s.
        private nonisolated static let sheetText = """
        REM DATE 1999
        PERFORMER "The Band"
        TITLE "The Album"
        FILE "album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            PERFORMER "Guest"
            INDEX 01 00:01:00
          TRACK 03 AUDIO
            TITLE "Three"
            INDEX 01 00:02:30
        """

        /// `Album/album.cue` + `Album/album.flac`.
        private func makeAlbum(in dir: TempDir, folder: String = "Album", name: String = "album",
                               sheet: String = sheetText, audio: String = "playback/a.flac") throws {
            try dir.copy(audio, to: "\(folder)/\(name).flac")
            try dir.write("\(folder)/\(name).cue", Data(sheet.replacingOccurrences(of: "album.flac", with: "\(name).flac").utf8))
        }

        private func session(_ scratch: TempDir? = nil) throws -> (ImportSession, CoverStore) {
            let covers = CoverStore(url: try (scratch ?? TempDir()).path("covers.sqlite"),
                                    thumbnailPixels: AppConstants.coverThumbnailPixels)
            return (ImportSession(coverStore: covers), covers)
        }

        private func names(_ inputs: [ReadInput], in dir: TempDir) -> [String] {
            inputs.map { input in
                switch input {
                case .file(let url): dir.relative([url])[0]
                case .cueTrack(let track), .cuePart(let track): dir.relative([track.sheet])[0] + ":" + String(track.pathNumber)
                case .unavailable(let url, _): "unavailable:" + dir.relative([url])[0]
                }
            }
        }

        // MARK: - Gathering

        @Test("a sheet adds its tracks, and the file it names is not added on its own")
        func referencedFileIsLeftOut() throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            let inputs = AudioFileGatherer.gatherInputs(from: [dir.url])
            #expect(names(inputs, in: dir) == ["Album/album.cue:1", "Album/album.cue:2", "Album/album.cue:3"])
            // The plain gatherer doesn't know about sheets.
            #expect(dir.relative(AudioFileGatherer.gather(from: [dir.url])) == ["Album/album.flac"])
        }

        @Test("the tracks come at the place of the sheet in the order; files that aren't named stay")
        func order() throws {
            let dir = try TempDir()
            try dir.write("A/a.mp3")
            try makeAlbum(in: dir, folder: "B")
            try dir.write("B/bonus.mp3")
            try dir.write("C/c.mp3")
            let inputs = AudioFileGatherer.gatherInputs(from: [dir.url])
            #expect(names(inputs, in: dir) == [
                "A/a.mp3", "B/album.cue:1", "B/album.cue:2", "B/album.cue:3", "B/bonus.mp3", "C/c.mp3",
            ])
        }

        @Test("directories are visited in natural order, sheets included")
        func naturalOrder() throws {
            let dir = try TempDir()
            try makeAlbum(in: dir, folder: "Disc 10", sheet: Self.sheetText.replacingOccurrences(of: "TRACK 0", with: "TRACK 1"))
            try makeAlbum(in: dir, folder: "Disc 2")
            let inputs = AudioFileGatherer.gatherInputs(from: [dir.url])
            #expect(names(inputs, in: dir).first == "Disc 2/album.cue:1")
            #expect(names(inputs, in: dir).last == "Disc 10/album.cue:13")
        }

        @Test("a directory without sheets gives the audio files, as the plain gatherer does")
        func noSheets() throws {
            let dir = try TempDir()
            try dir.write("X/01.mp3")
            try dir.write("X/02.flac")
            try dir.write("X/cover.jpg")
            let inputs = AudioFileGatherer.gatherInputs(from: [dir.url])
            #expect(names(inputs, in: dir) == dir.relative(AudioFileGatherer.gather(from: [dir.url])))
            #expect(names(inputs, in: dir) == ["X/01.mp3", "X/02.flac"])
        }

        @Test("a sheet given by itself works, and so does a sheet together with the file it names")
        func explicitInputs() throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            let sheet = dir.path("Album/album.cue")
            let audio = dir.path("Album/album.flac")
            let expected = ["Album/album.cue:1", "Album/album.cue:2", "Album/album.cue:3"]
            #expect(names(AudioFileGatherer.gatherInputs(from: [sheet]), in: dir) == expected)
            #expect(names(AudioFileGatherer.gatherInputs(from: [audio, sheet]), in: dir) == expected)
            #expect(names(AudioFileGatherer.gatherInputs(from: [sheet, audio, dir.url]), in: dir) == expected)
        }

        @Test("the audio file given by itself is a file: a sheet next to it is not looked for")
        func audioAlone() throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            let inputs = AudioFileGatherer.gatherInputs(from: [dir.path("Album/album.flac")])
            #expect(names(inputs, in: dir) == ["Album/album.flac"])
        }

        @Test("a sheet may be in any case")
        func uppercaseExtension() throws {
            let dir = try TempDir()
            try dir.copy("playback/a.flac", to: "Album/album.flac")
            try dir.write("Album/album.CUE", Data(Self.sheetText.utf8))
            #expect(names(AudioFileGatherer.gatherInputs(from: [dir.url]), in: dir).count == 3)
        }

        @Test("a file of a format that isn't supported adds nothing; other files next to it do")
        func unsupportedFormat() throws {
            let dir = try TempDir()
            try dir.write("Album/album.ape")
            try dir.write("Album/album.cue", Data(Self.sheetText.replacingOccurrences(of: "album.flac", with: "album.ape").utf8))
            try dir.write("Album/other.mp3")
            #expect(names(AudioFileGatherer.gatherInputs(from: [dir.url]), in: dir) == ["Album/other.mp3"])
        }

        @Test("tracks of unsupported files are dropped, the others of the sheet stay")
        func partlyUnsupported() throws {
            let dir = try TempDir()
            try dir.copy("playback/a.flac", to: "Album/a.flac")
            try dir.write("Album/b.wv")
            let sheet = """
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            FILE "b.wv" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
            """
            try dir.write("Album/x.cue", Data(sheet.utf8))
            #expect(names(AudioFileGatherer.gatherInputs(from: [dir.url]), in: dir) == ["Album/x.cue:1"])
        }

        @Test("a file that isn't there is still the sheet's track, and fails when it is read")
        func missingAudio() throws {
            let dir = try TempDir()
            try dir.write("Album/album.cue", Data(Self.sheetText.utf8))
            let inputs = AudioFileGatherer.gatherInputs(from: [dir.url])
            #expect(names(inputs, in: dir).count == 3)
        }

        @Test("nothing is guessed: another name or extension isn't the file")
        func noSiblingGuessing() throws {
            let dir = try TempDir()
            // The sheet says album.wav; album.flac is there, and not named, so it is just a file.
            try dir.copy("playback/a.flac", to: "Album/album.flac")
            try dir.write("Album/album.cue", Data(Self.sheetText.replacingOccurrences(of: "album.flac", with: "album.wav").utf8))
            let inputs = AudioFileGatherer.gatherInputs(from: [dir.url])
            #expect(names(inputs, in: dir) == ["Album/album.cue:1", "Album/album.cue:2", "Album/album.cue:3", "Album/album.flac"])
            if case .cueTrack(let track) = inputs[0] {
                #expect(track.audio.lastPathComponent == "album.wav")
            } else {
                Issue.record("expected a CUE track")
            }
        }

        @Test("another case names the same file only where the file system says so")
        func caseOfNames() throws {
            let dir = try TempDir()
            try dir.copy("playback/a.flac", to: "Album/album.flac")
            try dir.write("Album/album.cue", Data(Self.sheetText.replacingOccurrences(of: "album.flac", with: "ALBUM.FLAC").utf8))
            let caseInsensitive = FileManager.default.fileExists(atPath: dir.path("Album/ALBUM.FLAC").path)
            let found = names(AudioFileGatherer.gatherInputs(from: [dir.url]), in: dir)
            if caseInsensitive {
                #expect(found == ["Album/album.cue:1", "Album/album.cue:2", "Album/album.cue:3"])
            } else {
                #expect(found == ["Album/album.cue:1", "Album/album.cue:2", "Album/album.cue:3", "Album/album.flac"])
            }
        }

        @Test("a sheet that can't be read, or isn't one, names nothing: the files stay")
        func garbageSheet() throws {
            let dir = try TempDir()
            try dir.copy("playback/a.flac", to: "Album/album.flac")
            try dir.write("Album/album.cue", Data("this is not a cue sheet\n".utf8))
            try dir.write("Album/empty.cue")
            try dir.write("Album/binary.cue", Data((0...255).map { UInt8($0) }))
            #expect(names(AudioFileGatherer.gatherInputs(from: [dir.url]), in: dir) == ["Album/album.flac"])
        }

        @Test("a directory called something.cue is not a sheet")
        func directoryNamedCue() throws {
            let dir = try TempDir()
            try dir.write("x.cue/01.mp3")
            #expect(names(AudioFileGatherer.gatherInputs(from: [dir.url]), in: dir) == ["x.cue/01.mp3"])
        }

        @Test("hidden sheets are skipped like hidden files")
        func hiddenSheet() throws {
            let dir = try TempDir()
            try dir.copy("playback/a.flac", to: "Album/album.flac")
            try dir.write("Album/.album.cue", Data(Self.sheetText.utf8))
            #expect(names(AudioFileGatherer.gatherInputs(from: [dir.url]), in: dir) == ["Album/album.flac"])
        }

        @Test("a sheet names a file in a subdirectory or elsewhere: it is left out wherever it is found")
        func fileElsewhere() throws {
            let dir = try TempDir()
            try dir.copy("playback/a.flac", to: "Audio/disc.flac")
            try dir.write("Album/album.cue", Data(Self.sheetText.replacingOccurrences(of: "\"album.flac\"", with: "\"../Audio/disc.flac\"").utf8))
            let inputs = AudioFileGatherer.gatherInputs(from: [dir.url])
            #expect(names(inputs, in: dir) == ["Album/album.cue:1", "Album/album.cue:2", "Album/album.cue:3"])

            let sub = try TempDir()
            try sub.copy("playback/a.flac", to: "Album/CD1/disc.flac")
            try sub.write("Album/album.cue", Data(Self.sheetText.replacingOccurrences(of: "\"album.flac\"", with: "\"CD1/disc.flac\"").utf8))
            #expect(names(AudioFileGatherer.gatherInputs(from: [sub.url]), in: sub).count == 3)
        }

        @Test("every sheet takes its own files; two sheets for one file both give their tracks")
        func severalSheets() throws {
            let dir = try TempDir()
            try makeAlbum(in: dir, folder: "One")
            try makeAlbum(in: dir, folder: "Two", name: "disc")
            try dir.write("Two/alt.cue", Data(Self.sheetText.replacingOccurrences(of: "album.flac", with: "disc.flac").utf8))
            let found = names(AudioFileGatherer.gatherInputs(from: [dir.url]), in: dir)
            #expect(found.filter { $0.hasPrefix("One/") }.count == 3)
            #expect(found.filter { $0.hasPrefix("Two/alt.cue") }.count == 3)
            #expect(found.filter { $0.hasPrefix("Two/disc.cue") }.count == 3)
            #expect(!found.contains { $0.hasSuffix(".flac") })
        }

        @Test("the same sheet twice (a directory and the sheet in it) is read once")
        func duplicates() throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            let inputs = AudioFileGatherer.gatherInputs(from: [dir.url, dir.path("Album/album.cue"), dir.path("Album")])
            #expect(inputs.count == 3)
        }

        @Test("a sheet whose track numbers repeat still gives every track a path of its own")
        func uniquePaths() throws {
            let dir = try TempDir()
            let sheet = """
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            FILE "b.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            """
            try dir.copy("playback/a.flac", to: "Album/a.flac")
            try dir.copy("playback/b.flac", to: "Album/b.flac")
            try dir.write("Album/x.cue", Data(sheet.utf8))
            #expect(names(AudioFileGatherer.gatherInputs(from: [dir.url]), in: dir) == ["Album/x.cue:1", "Album/x.cue:2"])
        }

        @Test("the read inputs say what they stand for")
        func readInput() throws {
            let url = URL(fileURLWithPath: "/m/a.mp3")
            let track = CueSheet.parse(Self.sheetText).resolve(sheet: URL(fileURLWithPath: "/m/a.cue")).tracks[1]
            #expect(ReadInput.file(url).audioURL == url && ReadInput.file(url).resultURL == url)
            #expect(ReadInput.cueTrack(track).audioURL?.path == "/m/album.flac")
            #expect(ReadInput.cueTrack(track).resultURL.path == "/m/a.cue:2")
            #expect(ReadInput.unavailable(url, reason: "x").audioURL == nil)
            #expect(ReadInput.unavailable(url, reason: "x").resultURL == url)
        }

        // MARK: - Importing

        @Test("an album of one file and a sheet: tracks with the sheet's tags and lengths, none for the file itself")
        func importAlbum() async throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            let (session, _) = try session()

            let outcome = await session.run(inputs: [dir.url])

            #expect(!outcome.aborted)
            #expect(outcome.fileCount == 3)
            #expect(outcome.albums.count == 1)
            let album = outcome.albums[0]
            #expect(album.title == "The Album" && album.year == "1999")
            #expect(album.hasMultipleArtists)                           // "Guest" on track 2
            #expect(album.artist == AlbumBuilder.variousArtists)
            #expect(album.tracks.map(\.title) == ["One", "Two", "Three"])
            #expect(album.tracks.map(\.artist) == ["The Band", "Guest", "The Band"])
            #expect(album.tracks.map(\.number) == [1, 2, 3])
            #expect(album.tracks.map(\.codec) == ["FLAC", "FLAC", "FLAC"])
            #expect(dir.relative(album.tracks.map(\.url)) == Array(repeating: "Album/album.flac", count: 3))
            #expect(dir.relative(album.tracks.map { URL(fileURLWithPath: $0.path) }) == ["Album/album.cue:1", "Album/album.cue:2", "Album/album.cue:3"])
            #expect(album.tracks.map { $0.cue?.number } == [1, 2, 3])
            #expect(dir.relative([album.directory]) == ["Album"])

            let durations = album.tracks.compactMap(\.duration)
            #expect(durations.count == 3)
            #expect(durations[0] == 1.0 && abs(durations[1] - 1.4) < 1e-9)   // from the sheet
            #expect(abs(durations[2] - 0.7) < 0.01)                      // what is left of the file
            #expect(album.tracks[0].cue?.start == 0 && album.tracks[0].cue?.end == 1.0)
            #expect(abs((album.tracks[2].cue?.start ?? 0) - 2.4) < 1e-9 && album.tracks[2].cue?.end == nil)

            #expect(session.total == 3 && session.processed == 3)
            #expect(session.failed == 0 && session.successful == 3 && session.incomplete == 0)
        }

        @Test("a track that the sheet says little about is incomplete, not failed")
        func importIncomplete() async throws {
            let dir = try TempDir()
            let sheet = """
            FILE "album.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 00:01:00
            """
            try makeAlbum(in: dir, sheet: sheet)
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])

            #expect(session.failed == 0 && session.incomplete == 2 && session.successful == 0)
            let album = try #require(outcome.albums.first)
            #expect(album.title == TagFallback.album && album.artist == TagFallback.artist)
            #expect(album.tracks.map(\.title) == [TagFallback.title, TagFallback.title])
            #expect(album.tracks.map(\.number) == [1, 2])
        }

        @Test("without a year in the sheet the tracks are incomplete")
        func importWithoutYear() async throws {
            let dir = try TempDir()
            try makeAlbum(in: dir, sheet: Self.sheetText.replacingOccurrences(of: "REM DATE 1999\n", with: ""))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])
            #expect(session.incomplete == 3 && session.successful == 0)
            #expect(outcome.albums[0].year == nil)
        }

        @Test("the album's art: the folder image next to the sheet")
        func folderArt() async throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            try dir.copy("art/cover.jpg", to: "Album/cover.jpg")
            let (session, covers) = try session()
            let outcome = await session.run(inputs: [dir.url])

            #expect(session.albumsProcessed == 1 && session.artsProcessed == 1)
            let data = try #require(covers.data(for: outcome.albums[0].key))
            #expect(TestImages.inspect(data)?.width == AppConstants.coverThumbnailPixels)
        }

        @Test("the album's art: the picture embedded in the audio file")
        func embeddedArt() async throws {
            let dir = try TempDir()
            let sheet = """
            TITLE "Album"
            FILE "album.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 00:01:00
            """
            try makeAlbum(in: dir, sheet: sheet, audio: "formats/t_cover.flac")
            let (session, covers) = try session()
            let outcome = await session.run(inputs: [dir.url])

            #expect(session.albumsProcessed == 1 && session.artsProcessed == 1)
            #expect(covers.data(for: outcome.albums[0].key) != nil)
        }

        @Test("no art anywhere: none, and no trouble")
        func noArt() async throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            let (session, covers) = try session()
            let outcome = await session.run(inputs: [dir.url])
            #expect(session.albumsProcessed == 1 && session.artsProcessed == 0)
            #expect(covers.data(for: outcome.albums[0].key) == nil)
        }

        @Test("a sheet whose file is missing fails all its tracks and adds none")
        func importMissingAudio() async throws {
            let dir = try TempDir()
            try dir.write("Album/album.cue", Data(Self.sheetText.utf8))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])
            #expect(outcome.fileCount == 3)
            #expect(outcome.albums.isEmpty)
            #expect(session.total == 3 && session.processed == 3 && session.failed == 3)
        }

        @Test("a sheet whose file is not audio fails all its tracks")
        func importBrokenAudio() async throws {
            let dir = try TempDir()
            try dir.copy("broken/garbage.mp3", to: "Album/album.mp3")
            try dir.write("Album/album.cue", Data(Self.sheetText.replacingOccurrences(of: "album.flac", with: "album.mp3").utf8))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])
            #expect(outcome.albums.isEmpty)
            #expect(session.failed == 3)
        }

        @Test("a sheet that adds nothing is no file found: nothing to add")
        func importNothing() async throws {
            let dir = try TempDir()
            try dir.write("Album/album.ape")
            try dir.write("Album/album.cue", Data(Self.sheetText.replacingOccurrences(of: "album.flac", with: "album.ape").utf8))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])
            #expect(outcome.fileCount == 0 && outcome.albums.isEmpty && !outcome.aborted)
        }

        @Test("sheets and ordinary files together: albums in order, counts for all of them")
        func importMixed() async throws {
            let dir = try TempDir()
            try dir.copy("formats/t_v23.mp3", to: "A/01.mp3")
            try makeAlbum(in: dir, folder: "B")
            try dir.copy("formats/t_v24.mp3", to: "C/01.mp3")
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])

            #expect(outcome.fileCount == 5)
            #expect(session.total == 5 && session.processed == 5 && session.failed == 0)
            #expect(outcome.albums.map(\.title) == [Fixtures.album, "The Album", Fixtures.album])
            #expect(dir.relative(outcome.albums.map(\.directory)) == ["A", "B", "C"])
            #expect(outcome.albums.map(\.tracks.count) == [1, 3, 1])
        }

        @Test("two albums on two sheets in one directory stay two albums, each with its own tracks")
        func twoSheetsOneDirectory() async throws {
            let dir = try TempDir()
            try dir.copy("playback/a.flac", to: "Mix/one.flac")
            try dir.copy("playback/b.flac", to: "Mix/two.flac")
            let one = Self.sheetText.replacingOccurrences(of: "album.flac", with: "one.flac").replacingOccurrences(of: "The Album", with: "One")
            let two = """
            TITLE "Two"
            FILE "two.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Only"
                INDEX 01 00:00:00
            """
            try dir.write("Mix/one.cue", Data(one.utf8))
            try dir.write("Mix/two.cue", Data(two.utf8))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])
            #expect(outcome.albums.map(\.title) == ["One", "Two"])
            #expect(outcome.albums.map(\.tracks.count) == [3, 1])
            #expect(abs((outcome.albums[1].tracks[0].duration ?? 0) - RampFile.b.duration) < 0.01)
        }

        @Test("an album over two files: each track runs to the end of its own file")
        func twoFiles() async throws {
            let dir = try TempDir()
            try dir.copy("playback/a.flac", to: "Album/side a.flac")
            try dir.copy("playback/b.flac", to: "Album/side b.flac")
            let sheet = """
            TITLE "Two Sides"
            PERFORMER "Band"
            FILE "side a.flac" WAVE
              TRACK 01 AUDIO
                TITLE "A1"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "A2"
                INDEX 01 00:01:00
            FILE "side b.flac" WAVE
              TRACK 03 AUDIO
                TITLE "B1"
                INDEX 01 00:00:00
              TRACK 04 AUDIO
                TITLE "B2"
                INDEX 01 00:02:00
            """
            try dir.write("Album/album.cue", Data(sheet.utf8))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])

            let tracks = try #require(outcome.albums.first).tracks
            #expect(outcome.albums.count == 1)
            #expect(tracks.map(\.title) == ["A1", "A2", "B1", "B2"])
            #expect(tracks.map { $0.url.lastPathComponent } == ["side a.flac", "side a.flac", "side b.flac", "side b.flac"])
            let lengths = tracks.map { $0.duration ?? -1 }
            #expect(abs(lengths[1] - (RampFile.a.duration - 1)) < 0.01)     // to the end of side a
            #expect(abs(lengths[2] - 2.0) < 0.001)
            #expect(abs(lengths[3] - (RampFile.b.duration - 2)) < 0.01)     // to the end of side b
        }

        @Test("importing a playlist file that lists a sheet takes nothing of it, nor does a list of files")
        func playlistsAndFilesIgnoreSheets() async throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            try dir.write("list.m3u8", Data("Album/album.cue\n".utf8))
            let (first, _) = try session()
            let fromPlaylist = await first.run(playlists: [dir.path("list.m3u8")])
            #expect(fromPlaylist.fileCount == 0)

            let (second, _) = try session()
            let fromFiles = await second.run(files: [dir.path("Album/album.cue")])
            #expect(fromFiles.fileCount == 0)
        }

        /// A sheet with one `TRACK` per `FILE`, each at the start, saying nothing else: what CUETools writes.
        private func listingSheet(_ files: [String], extra: String = "") -> String {
            files.enumerated().map { index, file in
                "FILE \"\(file)\" WAVE\n  TRACK \(String(format: "%02d", index + 1)) AUDIO\n\(extra)    INDEX 01 00:00:00\n"
            }.joined()
        }

        @Test("a sheet that cuts a file and says nothing of the album: artist, album and year are the file's, the titles aren't")
        func cutTakesWhatItLacksFromTheFile() async throws {
            let dir = try TempDir()
            // t.flac is tagged TTitle/TArtist/TAlbum/2020/track 3; the tracks are parts of it.
            let sheet = "FILE \"album.flac\" WAVE\n TRACK 01 AUDIO\n  INDEX 01 00:00:00\n TRACK 02 AUDIO\n  INDEX 01 00:01:00\n"
            try makeAlbum(in: dir, sheet: sheet, audio: "formats/t.flac")
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])
            let tracks = try #require(outcome.albums.first?.tracks)
            #expect(tracks.map(\.title) == [TagFallback.title, TagFallback.title])
            #expect(tracks.allSatisfy { $0.artist == Fixtures.artist && $0.cue != nil })
            #expect(tracks.map(\.number) == [1, 2])
            #expect(outcome.albums[0].title == Fixtures.album)
        }

        @Test("a sheet that only lists tagged files adds those files themselves, in the sheet's order, with their own tags")
        func listingSheetAddsFiles() async throws {
            let dir = try TempDir()
            try dir.copy("formats/t.flac", to: "Album/02 b.flac")
            try dir.copy("formats/t.ogg", to: "Album/01 a.ogg")
            try dir.write("Album/x.cue", Data(listingSheet(["02 b.flac", "01 a.ogg"], extra: "    TITLE \"Sheet\"\n").utf8))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])

            #expect(!outcome.aborted && outcome.fileCount == 2)
            let entries = Playlist(albums: outcome.albums).entries
            #expect(entries.map(\.path) == [dir.path("Album/02 b.flac").path, dir.path("Album/01 a.ogg").path])
            #expect(entries.allSatisfy { $0.cue == nil })
            #expect(entries.allSatisfy { $0.title == Fixtures.title && $0.artist == Fixtures.artist })
            #expect(entries.map(\.trackNumber) == [3, 3])   // the file's, not the sheet's TRACK
            #expect(outcome.albums.count == 1)
        }

        @Test("a listing sheet gives its tags to a file that has none, as the plain file")
        func listingSheetTagsUntaggedFile() async throws {
            let dir = try TempDir()
            try dir.copy("formats/t_notags.flac", to: "Album/one.flac")
            let sheet = "PERFORMER \"The Band\"\nTITLE \"The Album\"\nREM DATE 1999\n"
                + "FILE \"one.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 01 00:00:00\n"
            try dir.write("Album/x.cue", Data(sheet.utf8))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])

            let track = try #require(outcome.albums.first?.tracks.first)
            #expect(track.path == dir.path("Album/one.flac").path && track.cue == nil)
            #expect(track.title == "One" && track.artist == "The Band" && track.number == 1)
            #expect(outcome.albums[0].title == "The Album")
            #expect(session.failed == 0)
        }

        @Test("a file's own tags beat what a listing sheet says")
        func fileBeatsListingSheet() async throws {
            let dir = try TempDir()
            try dir.copy("formats/t.flac", to: "Album/one.flac")
            let sheet = "PERFORMER \"The Band\"\nTITLE \"The Album\"\n"
                + "FILE \"one.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 01 00:00:00\n"
            try dir.write("Album/x.cue", Data(sheet.utf8))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])
            let track = try #require(outcome.albums.first?.tracks.first)
            #expect(track.title == Fixtures.title && track.artist == Fixtures.artist && outcome.albums[0].title == Fixtures.album)
        }

        @Test("a sheet that skips the start of a file's only track cuts it, and the sheet comes first")
        func skippingStartCuts() async throws {
            let dir = try TempDir()
            try dir.copy("formats/t.flac", to: "Album/one.flac")
            let sheet = "FILE \"one.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 00 00:00:00\n    INDEX 01 00:00:30\n"
            try dir.write("Album/x.cue", Data(sheet.utf8))
            let (session, _) = try session()
            let outcome = await session.run(inputs: [dir.url])
            let track = try #require(outcome.albums.first?.tracks.first)
            #expect(track.cue?.start == 0.4 && track.cue?.end == nil)
            #expect(track.title == "One")                    // the sheet's
            #expect(track.artist == Fixtures.artist)         // the file's, the sheet has none
            #expect(track.path == dir.path("Album/x.cue").path + ":1")
        }

        @Test("lyrics in the files of a listing sheet are kept; in a file cut into several tracks they are not")
        func lyricsOfListedFiles() async throws {
            let dir = try TempDir()
            try dir.copy("formats/l.flac", to: "Album/one.flac")
            try dir.write("Album/x.cue", Data(listingSheet(["one.flac"]).utf8))
            let scratch = try TempDir()
            let store = LyricsStore(url: scratch.path("lyrics.sqlite"))
            let session = ImportSession(coverStore: CoverStore(url: scratch.path("c.sqlite"),
                                                               thumbnailPixels: AppConstants.coverThumbnailPixels),
                                        lyricsStore: store)
            _ = await session.run(inputs: [dir.url])
            #expect(session.lyricsFound == 1)
        }

        @Test("lyrics embedded in the audio file are not attached to the tracks of a sheet that cuts it")
        func noLyrics() async throws {
            let dir = try TempDir()
            try makeAlbum(in: dir, audio: "formats/l.flac")
            let scratch = try TempDir()
            let store = LyricsStore(url: scratch.path("lyrics.sqlite"))
            let session = ImportSession(coverStore: CoverStore(url: scratch.path("c.sqlite"),
                                                               thumbnailPixels: AppConstants.coverThumbnailPixels),
                                        lyricsStore: store)
            _ = await session.run(inputs: [dir.url])
            #expect(session.lyricsFound == 0)
        }

        // MARK: - Reloading

        @Test("reloading: a plain file is read, a CUE track is looked up in its sheet again")
        func reloadInputs() throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            let plain = dir.path("x.mp3")
            let sheet = dir.path("Album/album.cue")
            let inputs = ImportSession.reloadInputs(for: [
                plain,
                URL(fileURLWithPath: sheet.path + ":2"),
                URL(fileURLWithPath: sheet.path + ":9"),                           // not in the sheet
                URL(fileURLWithPath: dir.path("Album/gone.cue").path + ":1"),      // no such sheet
                URL(fileURLWithPath: sheet.path + ":1"),
            ])
            #expect(inputs.count == 5)
            guard case .file(let first) = inputs[0], case .cuePart(let second) = inputs[1],
                  case .unavailable(_, let notInSheet) = inputs[2], case .unavailable(_, let noSheet) = inputs[3],
                  case .cuePart(let last) = inputs[4] else {
                Issue.record("unexpected inputs \(inputs)")
                return
            }
            #expect(first == plain)
            #expect(second.pathNumber == 2 && second.title == "Two" && second.start == 1.0)
            #expect(last.pathNumber == 1 && last.title == "One")
            #expect(notInSheet.contains("sheet") && noSheet.contains("sheet"))
        }

        @Test("reloading tracks of a sheet reads the sheet again; results come back in the order asked for")
        func reloadSession() async throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            try dir.copy("formats/t_v23.mp3", to: "x.mp3")
            try dir.write("Album/album.cue", Data(Self.sheetText.replacingOccurrences(of: "\"Two\"", with: "\"Deux\"")
                .replacingOccurrences(of: "00:01:00", with: "00:01:30").utf8))
            let sheet = dir.path("Album/album.cue")
            let files = [URL(fileURLWithPath: sheet.path + ":2"), dir.path("x.mp3"), URL(fileURLWithPath: sheet.path + ":7")]
            let (session, _) = try session()
            let outcome = await session.reload(files: files)

            #expect(!outcome.aborted)
            #expect(outcome.results.map(\.url.path) == files.map(\.path))
            #expect(outcome.results[0].tags.title == "Deux")
            #expect(abs((outcome.results[0].cue?.start ?? 0) - 1.4) < 1e-9)
            #expect(outcome.results[1].cue == nil && outcome.results[1].tags.title == Fixtures.title)
            #expect(outcome.results.map(\.status.isFailure) == [false, false, true])
            #expect(session.total == 3 && session.processed == 3 && session.failed == 1)
        }

        @Test("importing, editing the sheet and reloading brings the playlist up to date")
        func importThenReload() async throws {
            let dir = try TempDir()
            try makeAlbum(in: dir)
            let (first, _) = try session()
            let outcome = await first.run(inputs: [dir.url])
            let playlist = Playlist(albums: outcome.albums)
            let ids = playlist.entries.map(\.id)

            // The last track starts later and is renamed.
            try dir.write("Album/album.cue", Data(Self.sheetText.replacingOccurrences(of: "\"Three\"", with: "\"Trois\"")
                .replacingOccurrences(of: "00:02:30", with: "00:03:00").utf8))
            let (second, _) = try session()
            let reloaded = await second.reload(files: playlist.entries.map { URL(fileURLWithPath: $0.path) })
            let updated = playlist.updatingTags(from: reloaded.results)

            #expect(updated.entries.map(\.id) == ids)
            #expect(updated.entries.map(\.title) == ["One", "Two", "Trois"])
            #expect(updated.entries[2].cue?.start == 3.0)
            #expect(updated.entries[1].cue?.end == 3.0)
            #expect(updated.entries[1].duration == 2.0)
        }
    }
}
