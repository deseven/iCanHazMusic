import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("PictureBlock")
    struct PictureBlockTests {
        private let image = TestImages.make(width: 8, height: 8)

        @Test("extracts the image of a picture block")
        func extract() {
            let block = Synthetic.pictureBlock(image: image)
            #expect(PictureBlock.imageData(from: block) == image)
        }

        @Test("a block with description text")
        func withDescription() {
            var block = Data.be32(3) + .be32(9) + .ascii("image/png") + .be32(5) + .ascii("front")
            block += .be32(8) + .be32(8) + .be32(24) + .be32(0) + .be32(image.count) + image
            #expect(PictureBlock.imageData(from: block) == image)
        }

        @Test("garbage and truncated blocks are rejected")
        func rejects() {
            #expect(PictureBlock.imageData(from: Data()) == nil)
            #expect(PictureBlock.imageData(from: Data(repeating: 0xFF, count: 64)) == nil)
            let block = Synthetic.pictureBlock(image: image)
            #expect(PictureBlock.imageData(from: block.dropLast(5)) == nil)
            #expect(PictureBlock.imageData(from: Synthetic.pictureBlock(type: 99, image: image)) == nil)
            #expect(PictureBlock.imageData(from: Synthetic.pictureBlock(image: Data())) == nil)
        }

        @Test("normalize leaves ordinary images alone")
        func normalizePlain() {
            let jpeg = TestImages.make(width: 8, height: 8, type: .jpeg)
            #expect(PictureBlock.normalize(image) == image)
            #expect(PictureBlock.normalize(jpeg) == jpeg)
            #expect(PictureBlock.normalize(Data()) == Data())
        }

        @Test("normalize unwraps a raw and a base64 encoded picture block")
        func normalizeBlocks() {
            let block = Synthetic.pictureBlock(image: image)
            #expect(PictureBlock.normalize(block) == image)
            #expect(PictureBlock.normalize(Data(block.base64EncodedString().utf8)) == image)
            // Line-wrapped base64, as found in some files
            let wrapped = block.base64EncodedString(options: .lineLength64Characters)
            #expect(PictureBlock.normalize(Data(wrapped.utf8)) == image)
        }

        @Test("something that only looks like a block is returned unchanged")
        func normalizeLookalike() {
            let fake = Data([0, 0, 0, 1, 2, 3])
            #expect(PictureBlock.normalize(fake) == fake)
            let base64Fake = Data("AAAA not really".utf8)
            #expect(PictureBlock.normalize(base64Fake) == base64Fake)
        }
    }

    @MainActor @Suite("FlacArtwork")
    struct FlacArtworkTests {
        private let front = TestImages.make(width: 16, height: 16, type: .png)
        private let back = TestImages.make(width: 12, height: 12, type: .jpeg)

        private func write(_ data: Data) throws -> (TempDir, URL) {
            let dir = try TempDir()
            return (dir, try dir.write("x.flac", data))
        }

        @Test("detects a picture block")
        func detects() throws {
            let (_, file) = try write(Synthetic.flac(blocks: [(4, Data(repeating: 0, count: 10)), (6, Synthetic.pictureBlock(image: front))]))
            #expect(try FlacArtwork.hasPicture(url: file))
        }

        @Test("a file without pictures")
        func none() throws {
            let (_, file) = try write(Synthetic.flac(blocks: [(4, Data(repeating: 0, count: 10)), (1, Data(repeating: 0, count: 100))]))
            #expect(try !FlacArtwork.hasPicture(url: file))
            #expect(try FlacArtwork.readPicture(url: file) == nil)
        }

        @Test("reads the image")
        func reads() throws {
            let (_, file) = try write(Synthetic.flac(blocks: [(6, Synthetic.pictureBlock(type: 3, image: front))]))
            #expect(try FlacArtwork.readPicture(url: file) == front)
        }

        @Test("prefers the front cover over an earlier picture")
        func prefersFront() throws {
            let (_, file) = try write(Synthetic.flac(blocks: [
                (6, Synthetic.pictureBlock(type: 4, image: back)),
                (6, Synthetic.pictureBlock(type: 3, image: front)),
            ]))
            #expect(try FlacArtwork.readPicture(url: file) == front)
        }

        @Test("without a front cover the first picture is used")
        func firstWithoutFront() throws {
            let (_, file) = try write(Synthetic.flac(blocks: [
                (6, Synthetic.pictureBlock(type: 4, image: back)),
                (6, Synthetic.pictureBlock(type: 0, image: front)),
            ]))
            #expect(try FlacArtwork.readPicture(url: file) == back)
        }

        @Test("skips a leading ID3v2 tag")
        func id3Prefix() throws {
            let (_, file) = try write(Synthetic.flac(blocks: [(6, Synthetic.pictureBlock(image: front))], idv2Prefix: true))
            #expect(try FlacArtwork.hasPicture(url: file))
            #expect(try FlacArtwork.readPicture(url: file) == front)
        }

        @Test("a padding block (type 127) ends the walk")
        func paddingEnds() throws {
            let (_, file) = try write(Synthetic.flac(blocks: [(127, Data(repeating: 0, count: 8)), (6, Synthetic.pictureBlock(image: front))]))
            #expect(try !FlacArtwork.hasPicture(url: file))
        }

        @Test("not a FLAC file, a too short file and an unparsable picture")
        func invalid() throws {
            let (_, text) = try write(Data("this is not a flac file at all".utf8))
            #expect(try !FlacArtwork.hasPicture(url: text))
            #expect(try FlacArtwork.readPicture(url: text) == nil)

            let (_, tiny) = try write(Data("fL".utf8))
            #expect(try !FlacArtwork.hasPicture(url: tiny))

            let (_, empty) = try write(Data())
            #expect(try !FlacArtwork.hasPicture(url: empty))

            let (_, junk) = try write(Synthetic.flac(blocks: [(6, Data(repeating: 0xFF, count: 40))]))
            #expect(try FlacArtwork.hasPicture(url: junk))
            #expect(try FlacArtwork.readPicture(url: junk) == nil)
        }

        @Test("a file that was cut in the middle of the block headers")
        func truncated() throws {
            var data = Synthetic.flac(blocks: [(4, Data(repeating: 0, count: 10))])
            data.removeLast(8)
            let (_, file) = try write(data)
            #expect(try !FlacArtwork.hasPicture(url: file))
        }

        @Test("missing file throws")
        func missing() {
            #expect(throws: (any Error).self) { try FlacArtwork.hasPicture(url: URL(fileURLWithPath: "/nonexistent.flac")) }
            #expect(throws: (any Error).self) { try FlacArtwork.readPicture(url: URL(fileURLWithPath: "/nonexistent.flac")) }
        }

        @Test("a real FLAC with a cover")
        func realFile() throws {
            let url = try Fixtures.url("formats/t_cover.flac")
            #expect(try FlacArtwork.hasPicture(url: url))
            let image = try #require(try FlacArtwork.readPicture(url: url))
            let info = try #require(TestImages.inspect(image))
            #expect(info.width == 300)
            #expect(info.height == 200)
            #expect(try !FlacArtwork.hasPicture(url: Fixtures.url("formats/t.flac")))
        }
    }

    @MainActor @Suite("ExternalArtwork")
    struct ExternalArtworkTests {
        private func scan(_ files: [String]) throws -> ExternalArtwork.Listing {
            let dir = try TempDir()
            for f in files { try dir.write(f) }
            return ExternalArtwork.scan(directory: dir.url)
        }

        @Test("no images")
        func noImages() throws {
            let listing = try scan(["01.mp3", "notes.txt", "cover.gif"])
            #expect(listing.preferred == nil)
            #expect(listing.anyImage == nil)
        }

        @Test("a missing directory is just empty")
        func missingDirectory() {
            let listing = ExternalArtwork.scan(directory: URL(fileURLWithPath: "/nonexistent-dir"))
            #expect(listing.preferred == nil)
            #expect(listing.anyImage == nil)
        }

        @Test("cover, folder, album and front are preferred, in that order, case-insensitively")
        func nameOrder() throws {
            #expect(try scan(["front.jpg", "album.jpg", "folder.jpg", "cover.jpg"]).preferred == "cover.jpg")
            #expect(try scan(["front.jpg", "album.jpg", "folder.jpg"]).preferred == "folder.jpg")
            #expect(try scan(["front.jpg", "album.jpg"]).preferred == "album.jpg")
            #expect(try scan(["front.png"]).preferred == "front.png")
            #expect(try scan(["COVER.JPG"]).preferred == "COVER.JPG")
            #expect(try scan(["Folder.Png", "front.jpg"]).preferred == "Folder.Png")
        }

        @Test("the name outranks the extension, then jpg > jpeg > png")
        func extensionOrder() throws {
            #expect(try scan(["cover.png", "folder.jpg"]).preferred == "cover.png")
            #expect(try scan(["cover.png", "cover.jpeg", "cover.jpg"]).preferred == "cover.jpg")
            #expect(try scan(["cover.png", "cover.jpeg"]).preferred == "cover.jpeg")
        }

        @Test("other images are only the last resort, the first in natural order")
        func anyImage() throws {
            let listing = try scan(["img10.jpg", "img2.png", "img1.jpeg", "x.txt"])
            #expect(listing.preferred == nil)
            #expect(listing.anyImage == "img1.jpeg")

            let natural = try scan(["img10.jpg", "img2.png"])
            #expect(natural.anyImage == "img2.png")

            let withCover = try scan(["a.jpg", "cover.jpg"])
            #expect(withCover.preferred == "cover.jpg")
            #expect(withCover.anyImage == "a.jpg")

            // The fallback is never the preferred image itself, even if it sorts first.
            let coverSortsFirst = try scan(["cover.jpg", "other.png"])
            #expect(coverSortsFirst.preferred == "cover.jpg")
            #expect(coverSortsFirst.anyImage == "other.png")
            #expect(try scan(["cover.jpg"]).anyImage == nil)
        }

        @Test("hidden files (AppleDouble leftovers) are ignored")
        func hidden() throws {
            let listing = try scan(["._cover.jpg", ".folder.png"])
            #expect(listing.preferred == nil)
            #expect(listing.anyImage == nil)
        }

        @Test("names that merely contain a preferred name don't count")
        func substring() throws {
            let listing = try scan(["cover art.jpg", "my-cover.jpg", "cover.jpg.bak"])
            #expect(listing.preferred == nil)
            #expect(listing.anyImage == "cover art.jpg")
        }
    }

    @MainActor @Suite("ArtworkDirectoryCache")
    struct ArtworkDirectoryCacheTests {
        @Test("lists a directory once and serves everyone from that")
        func cached() async throws {
            let dir = try TempDir()
            let cover = try dir.write("cover.jpg")
            let cache = ArtworkDirectoryCache(timeout: 5)

            let first = await cache.listing(for: dir.url)
            #expect(first.preferred == "cover.jpg")

            try FileManager.default.removeItem(at: cover)
            let second = await cache.listing(for: dir.url)
            #expect(second.preferred == "cover.jpg")        // still the cached answer

            let other = try TempDir()
            let fresh = await cache.listing(for: other.url)
            #expect(fresh.preferred == nil)
        }

        @Test("concurrent requests agree")
        func concurrent() async throws {
            let dir = try TempDir()
            try dir.write("folder.png")
            let cache = ArtworkDirectoryCache(timeout: 5)
            let url = dir.url
            let names = await withTaskGroup(of: String?.self) { group in
                for _ in 0..<20 { group.addTask { await cache.listing(for: url).preferred } }
                var out: [String?] = []
                for await n in group { out.append(n) }
                return out
            }
            #expect(names.count == 20)
            #expect(names.allSatisfy { $0 == "folder.png" })
        }
    }
}
