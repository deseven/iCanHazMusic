// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// The APEv2 tag of WavPack and APE files, and the ID3v1 tag that may follow it or stand in for it. (Reading real files
    /// is in `TagReaderTests`, `LyricsTests` and `CueImportTests`; here the tags are made by hand.)
    @MainActor @Suite("APEv2 tags")
    struct ApeTagTests {
        private let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 1, 2, 3, 4, 5])

        /// A cover item's value: a file name, a NUL, the image.
        private func cover(_ name: String = "cover.jpg") -> Data { Data(name.utf8) + Data([0]) + image }

        private func read(_ data: Data) throws -> (tag: ApeTag?, id3v1: [TagField: String]?) {
            let file = try TempDir().write("x.ape", data)
            let fh = try FileHandle(forReadingFrom: file)
            defer { try? fh.close() }
            return try ApeTag.read(fh)
        }

        // MARK: Items

        @Test("text items are read with their keys as written, and mapped to the fields case-insensitively")
        func fields() throws {
            let tag = Synthetic.ape([
                ("Title", "A Title"), ("ARTIST", "An Artist"), ("album", "An Album"), ("Album Artist", "The Band"),
                ("Year", "1999"), ("Track", "3/12"), ("Lyrics", "Line one\nLine two"), ("Genre", "Rock"),
            ])
            let (found, _) = try read(Synthetic.audio() + tag)
            let parsed = try #require(found)
            #expect(parsed.items.map(\.key) == ["Title", "ARTIST", "album", "Album Artist", "Year", "Track", "Lyrics", "Genre"])
            #expect(parsed.fields == [
                .title: "A Title", .artist: "An Artist", .album: "An Album", .albumArtist: "The Band", .year: "1999",
                .track: "3/12", .lyrics: "Line one\nLine two",
            ])
        }

        @Test("of several values in an item the first is used, of several items for a field the first too")
        func firstWins() throws {
            let tag = Synthetic.ape([
                (key: "Artist", value: Data("First\0Second".utf8), flags: 0),
                (key: "Year", value: Data("2001".utf8), flags: 0),
                (key: "Date", value: Data("2002".utf8), flags: 0),
            ])
            let parsed = try #require(try read(Synthetic.audio() + tag).tag)
            #expect(parsed.fields == [.artist: "First", .year: "2001"])
        }

        @Test("text is UTF-8, or Latin-1 when that is not valid, and blank values are no values")
        func text() throws {
            let tag = Synthetic.ape([
                ("Title", Data("Sigur Rós – Ágætis".utf8), 0),
                ("Artist", Data([0x53, 0x69, 0x67, 0x75, 0x72, 0x20, 0x52, 0xF3, 0x73]), 0),
                ("Album", Data("  \r\n ".utf8), 0),
            ])
            let parsed = try #require(try read(Synthetic.audio() + tag).tag)
            #expect(parsed.fields == [.title: "Sigur Rós – Ágætis", .artist: "Sigur Rós"])
        }

        @Test("binary items and locators give no text, only where their value is")
        func binaryItems() throws {
            let tag = Synthetic.ape([
                (key: "Title", value: Data("binary".utf8), flags: 2),
                (key: "Artist", value: Data("http://x".utf8), flags: 4),
                (key: "Album", value: Data("Album".utf8), flags: 0),
            ])
            let data = Synthetic.audio() + tag
            let parsed = try #require(try read(data).tag)
            #expect(parsed.fields == [.album: "Album"])
            #expect(parsed.items.map(\.kind) == [.binary, .locator, .text])
            #expect(parsed.items[0].text == nil && parsed.items[1].text == nil)
            #expect(parsed.items[0].size == 6)
            #expect(data[Int(parsed.items[0].offset)..<Int(parsed.items[0].offset) + 6] == Data("binary".utf8))
        }

        @Test("a tag with a header starts at the header, one without at its first item")
        func start() throws {
            let audio = Synthetic.audio(100)
            let plain = Synthetic.ape([("Title", "T")])
            #expect(try #require(try read(audio + plain).tag).start == 100)
            let withHeader = Synthetic.ape([("Title", "T")], withHeader: true)
            let parsed = try #require(try read(audio + withHeader).tag)
            #expect(parsed.start == 100)
            #expect(parsed.fields == [.title: "T"])
        }

        @Test("what doesn't add up is no tag, or a tag as far as it goes")
        func damaged() throws {
            #expect(try read(Data()).tag == nil)
            #expect(try read(Synthetic.audio()).tag == nil)
            #expect(try read(Data("APETAGEX".utf8)).tag == nil)

            // A size bigger than the file.
            var tag = Synthetic.ape([("Title", "T")])
            tag.replaceSubrange((tag.count - 20)..<(tag.count - 16), with: Data.le32(1_000_000))
            #expect(try read(tag).tag == nil)

            // More items than there are: the ones that are there.
            tag = Synthetic.ape([("Title", "T"), ("Artist", "A")])
            tag.replaceSubrange((tag.count - 16)..<(tag.count - 12), with: Data.le32(50))
            #expect(try read(Synthetic.audio() + tag).tag?.fields == [.title: "T", .artist: "A"])

            // An item whose value reaches past the tag: it and what follows are dropped.
            var cut = Synthetic.ape([("Title", "T"), ("Artist", "Some artist")])
            let artist = try #require(cut.range(of: Data("Some artist".utf8)))
            // (in front of the value: the key and its NUL, the flags, the size)
            cut.replaceSubrange((artist.lowerBound - 15)..<(artist.lowerBound - 11), with: Data.le32(5000))
            #expect(try read(Synthetic.audio() + cut).tag?.fields == [.title: "T"])
        }

        // MARK: Covers

        @Test("the cover is Cover Art (Front), else any other Cover Art item, in any case")
        func coverChoice() throws {
            let both = Synthetic.ape([
                (key: "Cover Art (Back)", value: cover("back.jpg"), flags: 2),
                (key: "COVER ART (FRONT)", value: cover("front.jpg"), flags: 2),
            ])
            #expect(try #require(try read(Synthetic.audio() + both).tag).cover?.key == "COVER ART (FRONT)")

            let other = Synthetic.ape([(key: "cover art (other)", value: cover(), flags: 2), (key: "Title", value: Data("T".utf8), flags: 0)])
            #expect(try #require(try read(Synthetic.audio() + other).tag).cover?.key == "cover art (other)")

            let none = Synthetic.ape([("Title", "T"), ("Cover", "not that")])
            #expect(try #require(try read(Synthetic.audio() + none).tag).cover == nil)

            // An empty one, or a locator, isn't a picture.
            let unusable = Synthetic.ape([(key: "Cover Art (Front)", value: Data(), flags: 2),
                                          (key: "Cover Art (Back)", value: Data("http://x/y.jpg".utf8), flags: 4)])
            #expect(try #require(try read(Synthetic.audio() + unusable).tag).cover == nil)
        }

        @Test("the image of a cover is what follows the file name")
        func coverImage() {
            #expect(ApeTag.image(inCover: cover()) == image)
            #expect(ApeTag.image(inCover: cover("Cover Art (Front).jpg")) == image)
            // Without a name: the image itself, a JPEG with a NUL in its first bytes or a PNG.
            #expect(ApeTag.image(inCover: image) == image)
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
            #expect(ApeTag.image(inCover: png) == png)
            // A name and nothing after it, or no NUL where one is looked for.
            #expect(ApeTag.image(inCover: Data("cover.jpg\0".utf8)) == nil)
            #expect(ApeTag.image(inCover: Data("cover.jpg".utf8)) == nil)
            #expect(ApeTag.image(inCover: Data()) == nil)
        }

        @Test("an image of several megabytes is not read to find the tags around it")
        func bigCover() throws {
            let big = Data("big.jpg".utf8) + Data([0]) + Data(repeating: 0xAB, count: 5_000_000)
            let tag = Synthetic.ape([
                (key: "Title", value: Data("Before".utf8), flags: 0),
                (key: "Cover Art (Front)", value: big, flags: 2),
                (key: "Artist", value: Data("After".utf8), flags: 0),
            ])
            let file = try TempDir().write("x.wv", Synthetic.audio() + tag)
            let fh = try FileHandle(forReadingFrom: file)
            defer { try? fh.close() }
            let parsed = try #require(try ApeTag.read(fh).tag)
            #expect(parsed.fields == [.title: "Before", .artist: "After"])
            let item = try #require(parsed.cover)
            #expect(item.text == nil && item.size == big.count)
            #expect(try parsed.value(of: item, from: fh) == big)
        }

        // MARK: ID3v1

        @Test("an ID3v1 tag after the APEv2 tag comes along, and doesn't hide it")
        func id3v1AfterApe() throws {
            let v1 = Synthetic.id3v1(title: "V1 Title", artist: "V1 Artist", album: "V1 Album", year: "2011", track: 7)
            let (tag, id3v1) = try read(Synthetic.audio() + Synthetic.ape([("Title", "APE Title")]) + v1)
            #expect(tag?.fields == [.title: "APE Title"])
            #expect(id3v1 == [.title: "V1 Title", .artist: "V1 Artist", .album: "V1 Album", .year: "2011", .track: "7"])
        }

        @Test("an ID3v1 tag alone, and neither")
        func id3v1Alone() throws {
            let (tag, id3v1) = try read(Synthetic.audio() + Synthetic.id3v1(title: "T", artist: "A", album: "B", track: 0))
            #expect(tag == nil)
            #expect(id3v1 == [.title: "T", .artist: "A", .album: "B", .year: "2001"])   // track 0 is no track

            let (none, noV1) = try read(Synthetic.audio())
            #expect(none == nil && noV1 == nil)
        }

        @Test("ID3v1 text is Latin-1, padded with NULs or blanks")
        func id3v1Text() {
            var block = Synthetic.id3v1(title: "", artist: "", album: "", year: "", track: 0)
            block.replaceSubrange(3..<10, with: Data([0x42, 0x6A, 0xF6, 0x72, 0x6B, 0x20, 0x20]))   // "Björk  "
            block.replaceSubrange(33..<36, with: Data("   ".utf8))
            #expect(Id3v1.fields(block) == [.title: "Björk"])
            #expect(Id3v1.fields(Data(repeating: 0, count: 128)) == nil)
            #expect(Id3v1.fields(Data("TAG".utf8)) == nil)
        }

        // MARK: Files

        @Test("the cover of a WavPack or APE file, as it was written", arguments: ["t_cover.wv", "t_cover.ape"])
        func coverOfFile(name: String) async throws {
            let url = try Fixtures.url("formats/" + name)
            let data = try #require(try ApeTagBackend.embeddedArtwork(url: url))
            #expect(data == (try Fixtures.data("art/cover.jpg")))
            #expect(TestImages.inspect(data)?.width == 300)

            // The same through what the album art and the player use.
            #expect(await AlbumArtProcessor.load(.embedded(url)) == data)
        }

        @Test("a file without a cover has none", arguments: ["t.wv", "t.ape", "t_notags.wv", "t_notags.ape", "t_v1.wv"])
        func noCover(name: String) async throws {
            let url = try Fixtures.url("formats/" + name)
            #expect(try ApeTagBackend.embeddedArtwork(url: url) == nil)
            #expect(await AlbumArtProcessor.load(.embedded(url)) == nil)
        }

        @Test("a file that can't be read has no cover, and the backend says so")
        func unreadableCover() async throws {
            let url = try TempDir().path("nope.wv")
            #expect(throws: (any Error).self) { try ApeTagBackend.embeddedArtwork(url: url) }
            #expect(await AlbumArtProcessor.load(.embedded(url)) == nil)
        }

        @Test("only WavPack and APE files are for this backend")
        func handles() {
            for name in ["a.wv", "a.WV", "a.ape", "A.Ape", "/x/y.wv"] {
                #expect(ApeTagBackend.handles(URL(fileURLWithPath: "/x/" + name)), "\(name)")
            }
            for name in ["a.flac", "a.mp3", "a.wvc", "a.apl", "wv", "a.wv.bak"] {
                #expect(!ApeTagBackend.handles(URL(fileURLWithPath: "/x/" + name)), "\(name)")
            }
        }
    }
}
