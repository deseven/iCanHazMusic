import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("TrailingTags")
    struct TrailingTagsTests {
        private let longTitle = "A Title That Is Definitely Longer Than Thirty Bytes"
        private let longArtist = "An Artist Whose Name Does Not Fit Either"
        private let longAlbum = "An Album Name That Also Exceeds The Limit Of v1"

        private func read(_ data: Data) throws -> [TagField: String] {
            let dir = try TempDir()
            let file = try dir.write("x.mp3", data)
            return try TrailingTags.read(url: file)
        }

        private var v1: Data {
            Synthetic.id3v1(title: String(longTitle.prefix(30)), artist: String(longArtist.prefix(30)), album: String(longAlbum.prefix(30)))
        }

        @Test("a plain ID3v1 tag has nothing more to offer")
        func plainV1() throws {
            #expect(try read(Synthetic.audio() + v1).isEmpty)
        }

        @Test("recovers title, artist and album from Lyrics3v2 in front of ID3v1")
        func lyrics3() throws {
            let lyrics = Synthetic.lyrics3([("IND", "00"), ("ETT", longTitle), ("EAR", longArtist), ("EAL", longAlbum), ("LYR", "la la la")])
            let found = try read(Synthetic.audio() + lyrics + v1)
            #expect(found == [.title: longTitle, .artist: longArtist, .album: longAlbum])
        }

        @Test("Lyrics3v2 without an ID3v1 tag at the end")
        func lyrics3WithoutV1() throws {
            let lyrics = Synthetic.lyrics3([("ETT", longTitle)])
            #expect(try read(Synthetic.audio() + lyrics) == [.title: longTitle])
        }

        @Test("recovers values from APEv2 (keys are case-insensitive)")
        func ape() throws {
            let tag = Synthetic.ape([("Title", longTitle), ("ARTIST", longArtist), ("album", longAlbum), ("Genre", "Rock")])
            let found = try read(Synthetic.audio() + tag + v1)
            #expect(found == [.title: longTitle, .artist: longArtist, .album: longAlbum])
        }

        @Test("APEv2 with a header")
        func apeWithHeader() throws {
            let tag = Synthetic.ape([("Title", longTitle)], withHeader: true)
            #expect(try read(Synthetic.audio() + tag + v1) == [.title: longTitle])
        }

        @Test("binary APE items and unrelated items are ignored")
        func apeBinary() throws {
            let tag = Synthetic.ape([
                (key: "Title", value: Data("binary".utf8), flags: 2),
                (key: "Artist", value: Data(longArtist.utf8), flags: 0),
            ])
            #expect(try read(Synthetic.audio() + tag + v1) == [.artist: longArtist])
        }

        @Test("only the first of several NUL separated APE values is used")
        func apeMultipleValues() throws {
            let tag = Synthetic.ape([("Artist", Data("First\0Second".utf8), 0)])
            #expect(try read(Synthetic.audio() + tag) == [.artist: "First"])
        }

        @Test("Lyrics3 and APE can both be present in either order; on a conflict the one closest to the end wins")
        func both() throws {
            let lyrics = Synthetic.lyrics3([("ETT", longTitle)])
            let ape = Synthetic.ape([("Artist", longArtist), ("Title", "from ape")])
            #expect(try read(Synthetic.audio() + lyrics + ape + v1) == [.title: "from ape", .artist: longArtist])
            #expect(try read(Synthetic.audio() + ape + lyrics + v1) == [.title: longTitle, .artist: longArtist])
        }

        @Test("text is UTF-8, or Latin-1 when that is not valid")
        func encodings() throws {
            let utf8 = Synthetic.lyrics3([("ETT", Data("Sigur Rós – Ágætis".utf8))])
            #expect(try read(Synthetic.audio() + utf8) == [.title: "Sigur Rós – Ágætis"])

            let latin1 = Synthetic.lyrics3([("ETT", Data([0x53, 0x69, 0x67, 0x75, 0x72, 0x20, 0x52, 0xF3, 0x73]))])
            #expect(try read(Synthetic.audio() + latin1) == [.title: "Sigur Rós"])
        }

        @Test("values are trimmed and empty ones dropped")
        func trimming() throws {
            let lyrics = Synthetic.lyrics3([("ETT", "  padded \r\n"), ("EAR", "   ")])
            #expect(try read(Synthetic.audio() + lyrics) == [.title: "padded"])
        }

        @Test("files with an ID3v2 header are left alone")
        func id3v2Wins() throws {
            let lyrics = Synthetic.lyrics3([("ETT", longTitle)])
            let data = Data.ascii("ID3") + Data([4, 0, 0, 0, 0, 0, 0]) + Synthetic.audio() + lyrics + v1
            #expect(try read(data).isEmpty)
        }

        @Test("tiny and empty files")
        func tiny() throws {
            #expect(try read(Data()).isEmpty)
            #expect(try read(Data("abc".utf8)).isEmpty)
            #expect(try read(Data(repeating: 0xFF, count: 100)).isEmpty)
            #expect(try read(Data(repeating: 0xFF, count: 128)).isEmpty)
        }

        @Test("a Lyrics3 size that doesn't match the block is rejected")
        func badLyricsSize() throws {
            var lyrics = Synthetic.lyrics3([("ETT", longTitle)])
            lyrics.replaceSubrange((lyrics.count - 15)..<(lyrics.count - 9), with: Data.ascii("999999"))
            #expect(try read(Synthetic.audio(100) + lyrics).isEmpty)

            var wrongStart = Synthetic.lyrics3([("ETT", longTitle)])
            wrongStart.replaceSubrange(0..<11, with: Data.ascii("LYRICSBEGON"))
            #expect(try read(Synthetic.audio() + wrongStart).isEmpty)
        }

        @Test("a damaged Lyrics3 field stops parsing without losing earlier ones")
        func truncatedField() throws {
            // Field "EAR" announces 99999 bytes that aren't there.
            var block = Data.ascii("LYRICSBEGIN") + .ascii("ETT") + .ascii("00005") + .ascii("Title") + .ascii("EAR") + .ascii("99999") + .ascii("x")
            block += .ascii(String(format: "%06d", block.count)) + .ascii("LYRICS200")
            #expect(try read(Synthetic.audio() + block) == [.title: "Title"])
        }

        @Test("a missing file throws")
        func missingFile() {
            #expect(throws: (any Error).self) {
                try TrailingTags.read(url: URL(fileURLWithPath: "/nonexistent/x.mp3"))
            }
        }

        @Test("detects an APEv2 tag directly in front of ID3v1")
        func apeBeforeV1() throws {
            let dir = try TempDir()
            let ape = Synthetic.ape([("Title", longTitle)])
            let withApe = try dir.write("a.mp3", Synthetic.audio() + ape + v1)
            let withoutApe = try dir.write("b.mp3", Synthetic.audio() + v1)
            let apeOnly = try dir.write("c.mp3", Synthetic.audio() + ape)
            let lyrics = try dir.write("d.mp3", Synthetic.audio() + Synthetic.lyrics3([("ETT", longTitle)]) + v1)
            let tiny = try dir.write("e.mp3", Data("x".utf8))

            #expect(try TrailingTags.hasApeBeforeV1(url: withApe))
            #expect(try !TrailingTags.hasApeBeforeV1(url: withoutApe))
            #expect(try !TrailingTags.hasApeBeforeV1(url: apeOnly))
            #expect(try !TrailingTags.hasApeBeforeV1(url: lyrics))
            #expect(try !TrailingTags.hasApeBeforeV1(url: tiny))
        }

        // MARK: RawTags helpers

        private func raw(_ fields: [TagField: String]) -> RawTags {
            var r = RawTags()
            for (k, v) in fields { r.fields[k] = v }
            return r
        }

        @Test("a value of 30 bytes or more may be cut off")
        func mayBeTruncated() {
            #expect(raw([.title: String(repeating: "a", count: 30)]).mayBeTruncatedV1)
            #expect(raw([.album: String(repeating: "a", count: 31)]).mayBeTruncatedV1)
            #expect(!raw([.title: String(repeating: "a", count: 29), .artist: "x"]).mayBeTruncatedV1)
            #expect(!raw([:]).mayBeTruncatedV1)
            // year/track etc. don't count
            #expect(!raw([.year: String(repeating: "1", count: 40)]).mayBeTruncatedV1)
        }

        @Test("restoreTruncated only extends a cut-off start or fills a gap")
        func restore() {
            let cut = String(longTitle.prefix(30))
            var tags = raw([.title: cut, .artist: "Different Artist", .album: cut.uppercased()])
            tags.restoreTruncated(from: [.title: longTitle, .artist: "Something Else Entirely", .album: longAlbum])

            #expect(tags.fields[.title] == longTitle)
            #expect(tags.fields[.artist] == "Different Artist")     // not a prefix, kept
            #expect(tags.fields[.album] == cut.uppercased())        // not a prefix of the album, kept

            var caseInsensitive = raw([.title: cut.uppercased()])
            caseInsensitive.restoreTruncated(from: [.title: longTitle])
            #expect(caseInsensitive.fields[.title] == longTitle)

            var gap = raw([:])
            gap.restoreTruncated(from: [.artist: longArtist, .year: "1999"])
            #expect(gap.fields == [.artist: longArtist])            // year isn't restored

            var shorter = raw([.title: "Long enough title........."])
            shorter.restoreTruncated(from: [.title: "Long"])
            #expect(shorter.fields[.title] == "Long enough title.........")
        }
    }
}
