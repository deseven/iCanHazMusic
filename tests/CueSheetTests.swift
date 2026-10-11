// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// The CUE parser and what a sheet makes of the files it names. Pure text in, values out, no audio needed.
    @MainActor @Suite("CueSheet")
    struct CueSheetTests {
        private nonisolated static let sheetPath = "/Music/Album/album.cue"
        private nonisolated static let sheetURL = URL(fileURLWithPath: sheetPath)

        private func contents(_ text: String, sheet: String = sheetPath) -> CueSheet.Contents {
            CueSheet.parse(text).resolve(sheet: URL(fileURLWithPath: sheet))
        }

        /// Seconds of `07:00:37`.
        private nonisolated static let thirdStart: Double = 420 + 37.0 / 75

        /// A usual sheet: one file, a pregap before track 2.
        private static let usual = """
        REM GENRE Rock
        REM DATE 1999
        REM COMMENT "ExactAudioCopy v1.5"
        PERFORMER "The Band"
        TITLE "The Album"
        FILE "album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            PERFORMER "The Band"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 00 03:20:00
            INDEX 01 03:22:00
          TRACK 03 AUDIO
            TITLE "Three"
            PERFORMER "Guest"
            INDEX 01 07:00:37
        """

        // MARK: - What a sheet says

        @Test("the album's and the tracks' values are read")
        func basic() {
            let sheet = CueSheet.parse(Self.usual)
            #expect(sheet.title == "The Album")
            #expect(sheet.performer == "The Band")
            #expect(sheet.year == "1999")
            #expect(sheet.files == ["album.flac"])
            #expect(sheet.entries.map(\.number) == [1, 2, 3])
            #expect(sheet.entries.map(\.title) == ["One", "Two", "Three"])
            #expect(sheet.entries.map(\.performer) == ["The Band", nil, "Guest"])
            #expect(sheet.entries.allSatisfy { $0.isAudio && $0.file == 0 })
        }

        @Test("tracks run from their INDEX 01 to the next track's INDEX 01: a pregap belongs to the track before it")
        func startsAndEnds() throws {
            let result = contents(Self.usual)
            #expect(result.tracks.count == 3 && result.skipped == 0)
            let starts: [Double] = [0, 202, Self.thirdStart]
            #expect(result.tracks.map(\.start) == starts)
            let ends: [Double?] = [202, Self.thirdStart, nil]
            #expect(result.tracks.map(\.end) == ends)
            #expect(result.tracks.map(\.trackNumber) == [1, 2, 3])
            #expect(result.tracks.map(\.pathNumber) == [1, 2, 3])
            #expect(result.tracks.allSatisfy { $0.audio.path == "/Music/Album/album.flac" && $0.sheet == Self.sheetURL })
        }

        @Test("a track's own artist, the sheet's performer for the ones without, and the album and year of the sheet")
        func trackValues() {
            let tracks = contents(Self.usual).tracks
            #expect(tracks.map(\.artist) == ["The Band", nil, "Guest"])
            #expect(tracks.allSatisfy { $0.albumArtist == "The Band" && $0.album == "The Album" && $0.year == "1999" })
            #expect(tracks.map(\.title) == ["One", "Two", "Three"])
        }

        @Test("commands are case-insensitive, indentation and blank lines don't matter, unknown commands are ignored")
        func lenientSyntax() {
            let text = """

            \ttitle "Album"
               Catalog 1234567890123
            cdtextfile "x.cdt"
            file "a.flac" wave
              track 01 audio
                flags dcp
                isrc ABCDE1234567
                songwriter "Someone"
                title "One"
                pregap 00:02:00
                index 01 00:00:00
                postgap 00:01:00
              Track 2 Audio
                Index 01 01:00:00
            """
            let tracks = contents(text).tracks
            #expect(tracks.map(\.title) == ["One", nil])
            #expect(tracks.map(\.trackNumber) == [1, 2])
            #expect(tracks.map(\.end) == [60, nil])
            #expect(tracks[0].album == "Album")
        }

        @Test("any kind of line ending", arguments: ["\n", "\r\n", "\r"])
        func lineEndings(ending: String) {
            let text = Self.usual.components(separatedBy: "\n").joined(separator: ending)
            let tracks = contents(text).tracks
            #expect(tracks.map(\.title) == ["One", "Two", "Three"])
            let starts: [Double] = [0, 202, Self.thirdStart]
            #expect(tracks.map(\.start) == starts)
        }

        @Test("a byte order mark in front of the first line is no part of it")
        func bomInText() {
            let sheet = CueSheet.parse("\u{FEFF}TITLE \"Album\"\nFILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n  INDEX 01 00:00:00\n")
            #expect(sheet.title == "Album")
            #expect(sheet.entries.count == 1)
        }

        @Test("values: quoted, unquoted, with quotes inside, an unclosed quote, empty, padded")
        func values() {
            func title(_ line: String) -> String? {
                CueSheet.parse("TITLE \(line)").title
            }
            #expect(title("\"Quoted Title\"") == "Quoted Title")
            #expect(title("Unquoted Title") == "Unquoted Title")
            #expect(title("\"He said \"hi\"\"") == "He said \"hi\"")
            #expect(title("\"No closing quote") == "No closing quote")
            #expect(title("\"\"") == nil)
            #expect(title("") == nil)
            #expect(title("\"  padded  \"") == "padded")
            #expect(title("\"Ünï — 日本語 ☃\"") == "Ünï — 日本語 ☃")
            #expect(title("\"Semi; colon: and # hash\"") == "Semi; colon: and # hash")
        }

        @Test("an empty title or performer is no title or performer")
        func emptyValues() {
            let sheet = CueSheet.parse("PERFORMER \"\"\nFILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n  TITLE \"\"\n  PERFORMER \"\"\n  INDEX 01 00:00:00")
            #expect(sheet.performer == nil)
            #expect(sheet.entries[0].title == nil && sheet.entries[0].performer == nil)
        }

        @Test("TITLE and PERFORMER before the first TRACK are the album's, even after the FILE line")
        func albumValuesAfterFile() {
            let sheet = CueSheet.parse("""
            FILE "a.flac" WAVE
            TITLE "Album"
            PERFORMER "Artist"
              TRACK 01 AUDIO
                TITLE "One"
                INDEX 01 00:00:00
            """)
            #expect(sheet.title == "Album" && sheet.performer == "Artist")
            #expect(sheet.entries[0].title == "One" && sheet.entries[0].performer == nil)
        }

        // MARK: - FILE lines

        @Test("file names: quoted, unquoted, with spaces, with or without a type", arguments: [
            ("\"a b.flac\" WAVE", "a b.flac"),
            ("a.flac WAVE", "a.flac"),
            ("my file.flac WAVE", "my file.flac"),
            ("\"a.flac\"", "a.flac"),
            ("a.flac", "a.flac"),
            ("\"CD1/a.flac\" WAVE", "CD1/a.flac"),
            ("\"a.flac\" FLAC", "a.flac"),
            ("\"Ünï.flac\" WAVE", "Ünï.flac"),
        ])
        func fileNames(line: String, name: String) {
            #expect(CueSheet.parse("FILE \(line)").files == [name])
        }

        @Test("a FILE line without a name names nothing, and the tracks after it have no file")
        func emptyFile() {
            let sheet = CueSheet.parse("FILE\nFILE \"\" WAVE\n TRACK 01 AUDIO\n  INDEX 01 00:00:00")
            #expect(sheet.files.isEmpty)
            #expect(sheet.entries[0].file == nil)
            #expect(contents("FILE\n TRACK 01 AUDIO\n  INDEX 01 00:00:00").tracks.isEmpty)
        }

        @Test("names are taken as written: next to the sheet, in a subdirectory, absolute, or up a level")
        func resolution() {
            let text = """
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            FILE "CD 1/b.flac" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
            FILE "/Elsewhere/c.flac" WAVE
              TRACK 03 AUDIO
                INDEX 01 00:00:00
            FILE "../Other/d.flac" WAVE
              TRACK 04 AUDIO
                INDEX 01 00:00:00
            """
            let result = contents(text)
            #expect(result.tracks.map(\.audio.path) == [
                "/Music/Album/a.flac", "/Music/Album/CD 1/b.flac", "/Elsewhere/c.flac", "/Music/Other/d.flac",
            ])
            #expect(result.referenced.map(\.path) == result.tracks.map(\.audio.path))
        }

        @Test("nothing is guessed: another case, another extension or a backslash is a different file")
        func noGuessing() {
            let text = """
            FILE "ALBUM.FLAC" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            FILE "album.wav" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
            FILE "CD1\\album.flac" WAVE
              TRACK 03 AUDIO
                INDEX 01 00:00:00
            """
            #expect(contents(text).tracks.map(\.audio.path) == [
                "/Music/Album/ALBUM.FLAC", "/Music/Album/album.wav", "/Music/Album/CD1\\album.flac",
            ])
        }

        @Test("a file of a format that isn't supported gives no tracks, but is still the sheet's")
        func unsupportedFormat() {
            let result = contents("""
            FILE "album.ape" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 01:00:00
            """)
            #expect(result.tracks.isEmpty)
            #expect(result.skipped == 2)
            #expect(result.referenced.map(\.lastPathComponent) == ["album.ape"])
        }

        @Test("a sheet with several files takes the tracks of the supported ones only")
        func mixedFormats() {
            let result = contents("""
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            FILE "b.wv" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
              TRACK 03 AUDIO
                INDEX 01 01:00:00
            FILE "c.mp3" MP3
              TRACK 04 AUDIO
                INDEX 01 00:00:00
            """)
            #expect(result.tracks.map(\.trackNumber) == [1, 4])
            #expect(result.skipped == 2)
            #expect(result.referenced.map(\.lastPathComponent) == ["a.flac", "b.wv", "c.mp3"])
        }

        @Test("the same file named twice is one referenced file")
        func fileNamedTwice() {
            let result = contents("""
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
            FILE "a.flac" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
            """)
            #expect(result.referenced.count == 1)
            #expect(result.tracks.count == 2)
        }

        @Test("tracks before any FILE have no audio and are left out")
        func trackBeforeFile() {
            let result = contents("""
            TRACK 01 AUDIO
              INDEX 01 00:00:00
            FILE "a.flac" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
            """)
            #expect(result.tracks.map(\.trackNumber) == [2])
            #expect(result.skipped == 1)
        }

        // MARK: - Multiple files

        @Test("every file has its own tracks: the last track of a file runs to its end, the first starts where it says")
        func severalFiles() {
            let result = contents("""
            FILE "side a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 05:00:00
            FILE "side b.flac" WAVE
              TRACK 03 AUDIO
                INDEX 01 00:02:00
              TRACK 04 AUDIO
                INDEX 01 04:00:00
            """)
            #expect(result.tracks.map(\.audio.lastPathComponent) == ["side a.flac", "side a.flac", "side b.flac", "side b.flac"])
            #expect(result.tracks.map(\.start) == [0, 300, 2, 240])
            #expect(result.tracks.map(\.end) == [300, nil, 240, nil])
            #expect(result.tracks.map(\.pathNumber) == [1, 2, 3, 4])
        }

        @Test("a sheet whose numbers repeat (every disc starts at 01) is told apart by the place in the sheet")
        func repeatedNumbers() {
            let result = contents("""
            FILE "cd1.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 03:00:00
            FILE "cd2.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 04:00:00
            """)
            #expect(result.tracks.map(\.trackNumber) == [1, 2, 1, 2])   // what is shown
            #expect(result.tracks.map(\.pathNumber) == [1, 2, 3, 4])    // what tells them apart
            #expect(Set(result.tracks.map(\.slice.path)).count == 4)
        }

        @Test("the number in the path is the TRACK number, also when the sheet doesn't start at 1 or skips one")
        func pathNumbers() {
            let result = contents("""
            FILE "a.flac" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
              TRACK 05 AUDIO
                INDEX 01 01:00:00
              TRACK 06 AUDIO
                INDEX 01 02:00:00
            """)
            #expect(result.tracks.map(\.pathNumber) == [2, 5, 6])
            #expect(result.tracks.map(\.slice.path) == [
                "/Music/Album/album.cue:2", "/Music/Album/album.cue:5", "/Music/Album/album.cue:6",
            ])
        }

        // MARK: - Indexes

        @Test("INDEX 01 is the start; without one, the lowest index there is; without any the track is left out")
        func indexChoice() {
            let result = contents("""
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 00 00:00:00
                INDEX 01 00:02:00
                INDEX 02 00:30:00
              TRACK 02 AUDIO
                INDEX 02 01:00:00
                INDEX 03 01:30:00
              TRACK 03 AUDIO
                TITLE "no index"
              TRACK 04 AUDIO
                INDEX 01 03:00:00
            """)
            #expect(result.tracks.map(\.trackNumber) == [1, 2, 4])
            #expect(result.tracks.map(\.start) == [2, 60, 180])
            #expect(result.skipped == 1)
            // the track without an index doesn't end the one before it: that runs on to the next one that has a start
            #expect(result.tracks.map(\.end) == [60, 180, nil])
        }

        @Test("a hidden track before track 1 is not played: the first track starts at its own INDEX 01")
        func hiddenTrack() {
            let result = contents("""
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 00 00:00:00
                INDEX 01 02:30:00
              TRACK 02 AUDIO
                INDEX 01 05:00:00
            """)
            #expect(result.tracks.map(\.start) == [150, 300])
        }

        @Test("tracks that would have no length (two at one place, or out of order) are left out")
        func emptyTracks() {
            let result = contents("""
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 01:00:00
              TRACK 02 AUDIO
                INDEX 01 01:00:00
              TRACK 03 AUDIO
                INDEX 01 03:00:00
              TRACK 04 AUDIO
                INDEX 01 02:00:00
              TRACK 05 AUDIO
                INDEX 01 05:00:00
            """)
            // 1 ends where 2 starts (same place): empty. 3 ends before it starts (4 is at 2:00): empty.
            #expect(result.tracks.map(\.trackNumber) == [2, 4, 5])
            #expect(result.tracks.map(\.end) == [180, 300, nil])
            #expect(result.skipped == 2)
        }

        @Test("a data track is not played, but it ends the audio track before it")
        func dataTrack() {
            let result = contents("""
            FILE "disc.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 03:00:00
              TRACK 03 MODE1/2352
                INDEX 01 06:00:00
            """)
            #expect(result.tracks.map(\.trackNumber) == [1, 2])
            #expect(result.tracks.map(\.end) == [180, 360])
            #expect(result.skipped == 1)
        }

        @Test("a TRACK without a type is audio, one without a usable number is ignored")
        func trackLine() {
            let sheet = CueSheet.parse("""
            FILE "a.flac" WAVE
              TRACK 01
                INDEX 01 00:00:00
              TRACK AUDIO
                INDEX 01 01:00:00
              TRACK
                INDEX 01 02:00:00
              TRACK 04 audio
                INDEX 01 03:00:00
            """)
            // The index lines of the ignored TRACK lines belong to nothing.
            #expect(sheet.entries.map(\.number) == [1, 4])
            #expect(sheet.entries.allSatisfy { $0.isAudio })
            #expect(sheet.entries.map(\.indices) == [[1: 0], [1: 180]])
        }

        private nonisolated static let timeCases: [(String, Double)] = [
            ("00:00:00", 0.0), ("00:01:00", 1.0), ("01:00:00", 60.0), ("03:22:00", 202.0),
            ("00:00:75", 1.0), ("00:00:15", 0.2), ("120:00:00", 7200.0), ("74:59:74", 4499.0 + 74.0 / 75),
        ]

        @Test("times: MM:SS:FF with 75 frames to a second", arguments: timeCases)
        func time(text: String, seconds: Double) {
            #expect(CueSheet.time(text) == seconds)
        }

        @Test("times that aren't MM:SS:FF are not times", arguments: [
            "", "1", "01:00", "00:00:00:00", "aa:bb:cc", "-1:00:00", "00:-1:00", "00:00:-1", "00:00:", ":00:00", "1.5:00:00",
        ])
        func badTime(text: String) {
            #expect(CueSheet.time(text) == nil)
        }

        @Test("an INDEX line with a bad time is ignored (the rest of the track still counts)")
        func badIndexLine() {
            let result = contents("""
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 nonsense
                INDEX 02 00:30:00
              TRACK 02 AUDIO
                INDEX 01
                INDEX 01 01:00:00
            """)
            #expect(result.tracks.map(\.start) == [30, 60])
        }

        // MARK: - REM DATE

        @Test("the year: the sheet's, a track's own wins, other REM lines mean nothing", arguments: [
            ("REM DATE 1999", "1999"), ("REM DATE \"2005\"", "2005"), ("rem date 1987-05-02", "1987-05-02"),
            ("REM YEAR 1999", nil), ("REM GENRE 1999", nil), ("REM DATE", nil), ("REM", nil),
        ])
        func year(line: String, expected: String?) {
            #expect(CueSheet.parse(line).year == expected)
        }

        @Test("a track's REM DATE is its own")
        func trackYear() {
            let tracks = contents("""
            REM DATE 1999
            FILE "a.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                REM DATE 2003
                INDEX 01 01:00:00
            """).tracks
            #expect(tracks.map(\.year) == ["1999", "2003"])
        }

        // MARK: - Garbage

        @Test("text that isn't a sheet has no tracks", arguments: [
            "", "   \n\n  ", "hello world", "{\"json\": true}", "FILE", "TRACK 01 AUDIO", "INDEX 01 00:00:00", "\u{0}\u{1}\u{2}",
        ])
        func garbage(text: String) {
            let result = contents(text)
            #expect(result.tracks.isEmpty)
        }

        @Test("a sheet with only a file and no tracks has nothing to play, and names its file")
        func noTracks() {
            let result = contents("FILE \"a.flac\" WAVE")
            #expect(result.tracks.isEmpty && result.skipped == 0)
            #expect(result.referenced.map(\.lastPathComponent) == ["a.flac"])
        }

        // MARK: - Encodings

        @Test("UTF-8, with and without a byte order mark")
        func utf8() {
            let text = "TITLE \"Ünï — ☃\""
            #expect(CueSheet.decode(Data(text.utf8)) == text)
            #expect(CueSheet.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).hasSuffix(text))
            #expect(CueSheet.parse(CueSheet.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8))).title == "Ünï — ☃")
        }

        @Test("UTF-16 with a byte order mark, either way round")
        func utf16() throws {
            let text = "PERFORMER \"Ünï — 日本\"\nTITLE \"Album\""
            let little = Data([0xFF, 0xFE]) + (try #require(text.data(using: .utf16LittleEndian)))
            let big = Data([0xFE, 0xFF]) + (try #require(text.data(using: .utf16BigEndian)))
            for data in [little, big] {
                let sheet = CueSheet.parse(CueSheet.decode(data))
                #expect(sheet.performer == "Ünï — 日本")
                #expect(sheet.title == "Album")
            }
        }

        @Test("anything else is read as Windows-1252")
        func windows1252() {
            // "Café" with é as the single byte 0xE9 isn't UTF-8.
            let data = Data("TITLE \"Caf".utf8) + Data([0xE9]) + Data("\"\nPERFORMER \"".utf8) + Data([0x93]) + Data("Q".utf8) + Data([0x94, 0x22])
            let sheet = CueSheet.parse(CueSheet.decode(data))
            #expect(sheet.title == "Café")
            #expect(sheet.performer == "\u{201C}Q\u{201D}")    // curly quotes: 0x93/0x94 are not Latin-1 characters
        }

        @Test("bytes that are nothing at all still give a text")
        func undecodable() {
            let data = Data((0...255).map { UInt8($0) })
            #expect(!CueSheet.decode(data).isEmpty)
        }

        // MARK: - Files

        @Test("a sheet is read from a file, and nothing from one that isn't there or is far too big")
        func load() throws {
            let dir = try TempDir()
            let file = try dir.write("album.cue", Data(Self.usual.utf8))
            #expect(CueSheet.load(file)?.title == "The Album")
            #expect(CueSheet.contents(of: file)?.tracks.count == 3)
            #expect(CueSheet.load(dir.path("missing.cue")) == nil)
            #expect(CueSheet.contents(of: dir.path("missing.cue")) == nil)

            let huge = try dir.write("huge.cue", Data(repeating: 0x20, count: CueSheet.maxSize + 1))
            #expect(CueSheet.load(huge) == nil)
            #expect(CueSheet.load(dir.url) == nil)   // a directory
        }

        @Test("the sheet's directory is where names are looked for")
        func relativeToTheSheet() throws {
            let dir = try TempDir()
            let file = try dir.write("Some/Where/album.cue", Data(Self.usual.utf8))
            let tracks = try #require(CueSheet.contents(of: file)).tracks
            #expect(dir.relative(tracks.map(\.audio)) == Array(repeating: "Some/Where/album.flac", count: 3))
        }

        @Test("only files with the extension cue are sheets, in any case")
        func isCue() {
            for name in ["a.cue", "a.CUE", "a.Cue", "dir.x/a.cue"] {
                #expect(CueSheet.isCueFile(URL(fileURLWithPath: "/x/" + name)), "\(name)")
            }
            for name in ["a.cue.txt", "a.txt", "cue", "a.cue:1", "a.cue~"] {
                #expect(!CueSheet.isCueFile(URL(fileURLWithPath: "/x/" + name)), "\(name)")
            }
        }

        // MARK: - Pseudo paths

        @Test("the pseudo path of a track and how it is read back")
        func pseudoPath() throws {
            #expect(CuePath.make(sheet: "/m/a.cue", number: 3) == "/m/a.cue:3")
            let parsed = try #require(CuePath.parse("/m/a.cue:12"))
            #expect(parsed.sheet == "/m/a.cue" && parsed.number == 12)
            #expect(CuePath.parse("/m/A.CUE:1")?.sheet == "/m/A.CUE")
            #expect(CuePath.parse("/m/some: dir/a.cue:7")?.sheet == "/m/some: dir/a.cue")
            #expect(CuePath.parse("/m/a.cue:0")?.number == 0)
            #expect(CuePath.isCuePath("/m/a.cue:1"))
        }

        @Test("what isn't a pseudo path", arguments: [
            "/m/a.cue", "/m/a.flac", "/m/a.flac:1", "/m/a.cue:", "/m/a.cue:x", "/m/a.cue:-1", "/m/a.cue:1.5", "/m/a.cue:1 ",
            ":1", ".cue:1", "/m/a.cue:١", "",
        ])
        func notAPseudoPath(path: String) {
            #expect(CuePath.parse(path) == nil)
            #expect(!CuePath.isCuePath(path))
        }
    }
}
