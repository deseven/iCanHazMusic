// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AudioToolbox
import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("TagKeyMap")
    struct TagKeyMapTests {
        @Test("splits prefix and key, lowercasing the key")
        func parse() {
            #expect(TagKeyMap.parse(identifier: "id3/TPE1") == ("id3", "tpe1"))
            #expect(TagKeyMap.parse(identifier: "vorb/ALBUMARTIST") == ("vorb", "albumartist"))
            #expect(TagKeyMap.parse(identifier: "caaf/info-title") == ("caaf", "info-title"))
        }

        @Test("percent-decodes the key")
        func percentDecoding() {
            #expect(TagKeyMap.parse(identifier: "vorb/ALBUM%20ARTIST") == ("vorb", "album artist"))
        }

        @Test("handles the Latin-1 © of MP4 atoms (not valid UTF-8 when decoded)")
        func mp4Atoms() {
            #expect(TagKeyMap.parse(identifier: "itsk/%A9ART") == ("itsk", "©art"))
            #expect(TagKeyMap.parse(identifier: "itsk/%a9nam") == ("itsk", "©nam"))
            #expect(TagKeyMap.table[TagKeyMap.parse(identifier: "itsk/%A9alb").key] == .album)
        }

        @Test("keys without a prefix (ID3v2.2 from AVFoundation) still parse")
        func bareKeys() {
            #expect(TagKeyMap.parse(identifier: "TT2") == ("", "tt2"))
            #expect(TagKeyMap.table["tt2"] == .title)
            #expect(TagKeyMap.table["tp1"] == .artist)
            #expect(TagKeyMap.table["tal"] == .album)
            #expect(TagKeyMap.table["tye"] == .year)
            #expect(TagKeyMap.table["trk"] == .track)
        }

        @Test("maps the common native keys of every container onto the canonical fields")
        func mapping() {
            let cases: [(String, TagField)] = [
                ("id3/TIT2", .title), ("id3/TPE1", .artist), ("id3/TPE2", .albumArtist), ("id3/TALB", .album),
                ("id3/TYER", .year), ("id3/TDRC", .year), ("id3/TRCK", .track), ("id3/TCOM", .composer),
                ("vorb/TITLE", .title), ("vorb/ARTIST", .artist), ("vorb/ALBUMARTIST", .albumArtist),
                ("vorb/PERFORMER", .performer), ("vorb/BAND", .band), ("vorb/DATE", .year),
                ("vorb/TRACKNUMBER", .track), ("vorb/DISCOGS_ARTIST_LIST", .discogsArtist),
                ("itsk/%A9nam", .title), ("itsk/%A9ART", .artist), ("itsk/aART", .albumArtist),
                ("itsk/%A9alb", .album), ("itsk/%A9day", .year), ("itsk/trkn", .track),
                ("caaf/info-title", .title), ("caaf/info-album artist", .albumArtist), ("caaf/info-track", .track),
            ]
            for (identifier, expected) in cases {
                #expect(TagKeyMap.table[TagKeyMap.parse(identifier: identifier).key] == expected, "\(identifier)")
            }
            #expect(TagKeyMap.table[TagKeyMap.parse(identifier: "id3/TXXX").key] == nil)
        }

        @Test("AudioToolbox info dictionary keys")
        func audioFileKeys() {
            #expect(TagKeyMap.audioFileTable["title"] == .title)
            #expect(TagKeyMap.audioFileTable["track number"] == .track)
            #expect(TagKeyMap.audioFileTable["recorded date"] == .year)
            #expect(TagKeyMap.audioFileTable["approximate duration in seconds"] == nil)
        }
    }

    @MainActor @Suite("RawTags")
    struct RawTagsTests {
        @Test("set trims and ignores empty values")
        func setTrims() {
            var raw = RawTags()
            raw.set(.title, "  Hello \n")
            raw.set(.artist, "   ")
            raw.set(.album, "")
            raw.set(.year, "\u{0}2020\u{0}")
            #expect(raw.fields == [.title: "Hello", .year: "2020"])
        }

        @Test("the first value of a field wins")
        func firstWins() {
            var raw = RawTags()
            raw.set(.title, "First")
            raw.set(.title, "Second")
            #expect(raw.fields[.title] == "First")
        }

        @Test("merge only fills what is missing")
        func merge() {
            var a = RawTags()
            a.set(.title, "A title")
            var b = RawTags()
            b.set(.title, "B title")
            b.set(.artist, "B artist")
            b.duration = 12
            a.merge(b)
            #expect(a.fields == [.title: "A title", .artist: "B artist"])
            #expect(a.duration == 12)

            var c = RawTags()
            c.duration = 99
            a.merge(c)
            #expect(a.duration == 12)
        }

        @Test("artwork presence: unknown stays unknown, any yes wins")
        func artworkFlag() {
            var a = RawTags()
            let unknown = RawTags()
            a.merge(unknown)
            #expect(a.hasArtwork == nil)

            var no = RawTags()
            no.hasArtwork = false
            a.merge(no)
            #expect(a.hasArtwork == false)

            var yes = RawTags()
            yes.hasArtwork = true
            a.merge(yes)
            #expect(a.hasArtwork == true)

            a.merge(no)
            #expect(a.hasArtwork == true)
        }
    }

    @MainActor @Suite("Tag finalization")
    struct TagFinalizeTests {
        private func finalize(_ fields: [TagField: String], duration: TimeInterval? = nil) -> (TrackTags, TagReadStatus) {
            var raw = RawTags()
            for (k, v) in fields { raw.set(k, v) }
            raw.duration = duration
            return TagReader.finalize(raw: raw, failed: nil)
        }

        @Test("complete tags")
        func complete() {
            let (tags, status) = finalize([.title: "T", .artist: "A", .album: "B", .year: "1999", .track: "5"], duration: 61)
            #expect(status == .complete)
            #expect(tags.title == "T")
            #expect(tags.artist == "A")
            #expect(tags.album == "B")
            #expect(tags.year == "1999")
            #expect(tags.trackNumber == 5)
            #expect(tags.duration == 61)
        }

        @Test("missing fields fall back and are listed")
        func partial() {
            let (tags, status) = finalize([.title: "T"])
            #expect(status == .partial(fallbacks: ["artist", "album"]))
            #expect(tags.title == "T")
            #expect(tags.artist == TagFallback.artist)
            #expect(tags.album == TagFallback.album)

            let (_, onlyTitleMissing) = finalize([.artist: "A", .album: "B"])
            #expect(onlyTitleMissing == .partial(fallbacks: ["title"]))
        }

        @Test("nothing at all is noTags, with all fallbacks applied")
        func noTags() {
            let (tags, status) = finalize([.year: "2000", .track: "1"])
            #expect(status == .noTags)
            #expect(tags.title == TagFallback.title)
            #expect(tags.artist == TagFallback.artist)
            #expect(tags.album == TagFallback.album)
            #expect(tags.year == "2000")
        }

        @Test("artist fallback chain: album artist > performer > band > discogs > composer")
        func artistChain() {
            let base: [TagField: String] = [.title: "T", .album: "B"]
            var fields = base.merging([.composer: "c", .discogsArtist: "d", .band: "b", .performer: "p", .albumArtist: "aa"]) { $1 }
            for (field, expected) in [(TagField.albumArtist, "aa"), (.performer, "p"), (.band, "b"), (.discogsArtist, "d"), (.composer, "c")] {
                let (tags, status) = finalize(fields)
                #expect(tags.artist == expected)
                #expect(status == .complete)
                fields[field] = nil
            }
            #expect(finalize(fields).0.artist == TagFallback.artist)
        }

        @Test("a real artist beats every fallback")
        func artistWins() {
            let (tags, _) = finalize([.title: "T", .album: "B", .artist: "Real", .albumArtist: "Other"])
            #expect(tags.artist == "Real")
        }

        @Test("the year is the first four digits")
        func year() {
            #expect(finalize([.year: "2019-05-06"]).0.year == "2019")
            #expect(finalize([.year: "May 1999"]).0.year == "1999")
            #expect(finalize([.year: "sometime"]).0.year == "sometime")
        }

        @Test("the track number is the leading integer")
        func trackNumber() {
            #expect(finalize([.track: "3"]).0.trackNumber == 3)
            #expect(finalize([.track: "03"]).0.trackNumber == 3)
            #expect(finalize([.track: "3/12"]).0.trackNumber == 3)
            #expect(finalize([.track: "abc"]).0.trackNumber == nil)
            #expect(finalize([:]).0.trackNumber == nil)
        }

        @Test("a failure keeps the duration but nothing else")
        func failed() {
            var raw = RawTags()
            raw.set(.title, "T")
            raw.duration = 5
            let (tags, status) = TagReader.finalize(raw: raw, failed: "boom")
            #expect(status == .failed("boom"))
            #expect(status.isFailure)
            #expect(tags.title == TagFallback.title)
            #expect(tags.duration == 5)

            #expect(TagReader.finalize(raw: RawTags(), failed: "").1 == .failed("unknown error"))
        }

        @Test("only failures are failures")
        func isFailure() {
            #expect(!TagReadStatus.complete.isFailure)
            #expect(!TagReadStatus.noTags.isFailure)
            #expect(!TagReadStatus.partial(fallbacks: ["artist"]).isFailure)
        }
    }

    @MainActor @Suite("AudioFileBackend")
    struct AudioFileBackendTests {
        @Test("describes the known OSStatus values")
        func describe() {
            #expect(AudioFileBackend.describe(kAudioFileUnsupportedFileTypeError) == "unsupported file type")
            #expect(AudioFileBackend.describe(kAudioFileInvalidFileError) == "invalid or corrupt file")
            #expect(AudioFileBackend.describe(kAudioFileFileNotFoundError) == "file not found")
            #expect(AudioFileBackend.describe(kAudioFilePermissionsError) == "permission denied")
            #expect(AudioFileBackend.describe(2003334207).contains("wht?"))
        }

        @Test("unknown statuses are shown as four-char codes when printable")
        func fourCC() {
            let code = OSStatus(bitPattern: 0x61626364)   // 'abcd'
            #expect(AudioFileBackend.describe(code) == "'abcd' (\(code))")
            #expect(AudioFileBackend.describe(-1) == "OSStatus -1")
        }

        @Test("reading a file that isn't there throws")
        func missingFile() {
            #expect(throws: TagReadError.self) {
                try AudioFileBackend.read(url: URL(fileURLWithPath: "/nonexistent/file.mp3"))
            }
        }

        @Test("reads a real file")
        func realFile() throws {
            let raw = try AudioFileBackend.read(url: Fixtures.url("formats/t.flac"))
            #expect(raw.fields[.title] == Fixtures.title)
            #expect(raw.fields[.artist] == Fixtures.artist)
            let duration = try #require(raw.duration)
            #expect(abs(duration - Fixtures.duration) < 0.2)
        }
    }

    @MainActor @Suite("TagReadError")
    struct TagReadErrorTests {
        @Test("descriptions")
        func descriptions() {
            #expect(TagReadError.unreadable("x").localizedDescription == "x")
            #expect(TagReadError.timeout(30).localizedDescription == "timed out after 30 s")
        }
    }
}
