import CoreGraphics
import ImageIO
import Foundation
import SQLite3
import Testing
import UniformTypeIdentifiers
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("CoverStore")
    struct CoverStoreTests {
        private func makeStore(_ dir: TempDir, pixels: Int = 112) -> CoverStore {
            CoverStore(url: dir.path(".cache/covers.sqlite"), thumbnailPixels: pixels)
        }

        @Test("stores and returns data, creating the database and its directory on first use")
        func roundTrip() throws {
            let dir = try TempDir()
            let store = makeStore(dir)
            #expect(store.data(for: "k") == nil)
            store.store(Data([1, 2, 3]), for: "k")
            #expect(store.data(for: "k") == Data([1, 2, 3]))
            #expect(FileManager.default.fileExists(atPath: dir.path(".cache/covers.sqlite").path))
        }

        @Test("storing again replaces")
        func replace() throws {
            let store = makeStore(try TempDir())
            store.store(Data([1]), for: "k")
            store.store(Data([2, 2]), for: "k")
            #expect(store.data(for: "k") == Data([2, 2]))
        }

        @Test("keys are independent, and can hold any text")
        func keys() throws {
            let store = makeStore(try TempDir())
            let separator = AlbumKey.make(directory: URL(fileURLWithPath: "/M/Ünï cödé ☃"), title: "a'b\"c;--")
            store.store(Data([1]), for: separator)
            store.store(Data([2]), for: "/M/B")
            store.store(Data([3]), for: "")
            #expect(store.data(for: separator) == Data([1]))
            #expect(store.data(for: "/M/B") == Data([2]))
            #expect(store.data(for: "") == Data([3]))
            #expect(store.data(for: "/M/C") == nil)
            // Keys differing only after an embedded NUL are still different keys.
            store.store(Data([4]), for: "a\0b")
            #expect(store.data(for: "a") == nil)
            #expect(store.data(for: "a\0b") == Data([4]))
        }

        @Test("larger blobs")
        func blob() throws {
            let store = makeStore(try TempDir())
            let data = Data((0..<200_000).map { UInt8($0 % 251) })
            store.store(data, for: "big")
            #expect(store.data(for: "big") == data)
        }

        @Test("data persists across instances")
        func persistence() throws {
            let dir = try TempDir()
            makeStore(dir).store(Data([9]), for: "k")
            #expect(makeStore(dir).data(for: "k") == Data([9]))
        }

        @Test("a different thumbnail size drops the old thumbnails")
        func sizeChange() throws {
            let dir = try TempDir()
            makeStore(dir, pixels: 112).store(Data([1]), for: "k")
            let bigger = makeStore(dir, pixels: 224)
            #expect(bigger.data(for: "k") == nil)
            bigger.store(Data([2]), for: "k")
            #expect(makeStore(dir, pixels: 224).data(for: "k") == Data([2]))
        }

        @Test("the thumbnail size is kept in user_version")
        func userVersion() throws {
            let dir = try TempDir()
            makeStore(dir, pixels: 130).store(Data([1]), for: "k")

            var db: OpaquePointer?
            #expect(sqlite3_open_v2(dir.path(".cache/covers.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            #expect(sqlite3_step(statement) == SQLITE_ROW)
            #expect(sqlite3_column_int(statement, 0) == 130)
        }

        @Test("an unusable database is a cache miss, never a crash")
        func brokenDatabase() throws {
            let dir = try TempDir()
            try dir.write(".cache/covers.sqlite", Data("this is not a database, just text".utf8))
            let store = makeStore(dir)
            #expect(store.data(for: "k") == nil)
            store.store(Data([1]), for: "k")          // dropped silently
            #expect(store.data(for: "k") == nil)
        }

        @Test("a location that can't be created is a cache miss too")
        func unusableLocation() throws {
            let dir = try TempDir()
            try dir.write("file")
            let store = CoverStore(url: dir.path("file/sub/covers.sqlite"), thumbnailPixels: 112)
            store.store(Data([1]), for: "k")
            #expect(store.data(for: "k") == nil)
        }

        @Test("concurrent use")
        func concurrent() async throws {
            let store = makeStore(try TempDir())
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<50 {
                    group.addTask {
                        store.store(Data([UInt8(i)]), for: "k\(i)")
                        _ = store.data(for: "k\(i)")
                    }
                }
            }
            for i in 0..<50 { #expect(store.data(for: "k\(i)") == Data([UInt8(i)])) }
        }
    }

    @MainActor @Suite("Thumbnailer")
    struct ThumbnailerTests {
        @Test("always the requested square size, whatever the input shape", arguments: [
            (400, 400), (800, 200), (200, 800), (50, 30), (112, 112), (1, 1), (3000, 2000),
        ])
        func size(width: Int, height: Int) throws {
            let data = TestImages.make(width: width, height: height)
            let thumb = try #require(Thumbnailer.thumbnail(from: data, pixels: 112))
            let info = try #require(TestImages.inspect(thumb))
            #expect(info.width == 112)
            #expect(info.height == 112)
        }

        @Test("opaque images become JPEG, images with transparency PNG")
        func formats() throws {
            let opaque = try #require(Thumbnailer.thumbnail(from: TestImages.make(width: 200, height: 200), pixels: 64))
            #expect(TestImages.inspect(opaque)?.type == UTType.jpeg.identifier)

            let alpha = try #require(Thumbnailer.thumbnail(from: TestImages.make(width: 200, height: 200, alpha: true), pixels: 64))
            #expect(TestImages.inspect(alpha)?.type == UTType.png.identifier)
        }

        @Test("JPEG input works as well")
        func jpegInput() throws {
            let data = TestImages.make(width: 300, height: 200, type: .jpeg)
            let thumb = try #require(Thumbnailer.thumbnail(from: data, pixels: 50))
            #expect(TestImages.inspect(thumb)?.width == 50)
        }

        @Test("the image is cropped to the center, not squeezed")
        func centerCrop() throws {
            // 300x100: left third red... the image is split in halves, so the centered square
            // 100x100 contains half red and half blue; a squeeze would too, but a crop of
            // a left-aligned region would not. Check the thumbnail's middle row.
            let data = TestImages.make(width: 400, height: 100)
            let thumb = try #require(Thumbnailer.thumbnail(from: data, pixels: 40))
            let image = try #require(CGImageSourceCreateWithData(thumb as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let left = try #require(pixel(image, x: 2, y: 20))
            let right = try #require(pixel(image, x: 37, y: 20))
            #expect(left.r > 200 && left.b < 80)         // red half
            #expect(right.b > 200 && right.r < 80)       // blue half
        }

        @Test("data that isn't an image")
        func notAnImage() {
            #expect(Thumbnailer.thumbnail(from: Data(), pixels: 64) == nil)
            #expect(Thumbnailer.thumbnail(from: Data("not an image".utf8), pixels: 64) == nil)
            #expect(Thumbnailer.thumbnail(from: Data(repeating: 0xFF, count: 1000), pixels: 64) == nil)
        }

        @Test("a truncated image")
        func truncated() throws {
            let full = TestImages.make(width: 200, height: 200, type: .jpeg)
            // Either nil or a (partially decoded) thumbnail, but never a crash.
            if let thumb = Thumbnailer.thumbnail(from: full.prefix(full.count / 2), pixels: 64) {
                #expect(TestImages.inspect(thumb)?.width == 64)
            }
        }

        @Test("the fixture covers")
        func fixtures() throws {
            for name in ["art/cover.jpg", "art/portrait.png", "art/square.jpg", "art/alpha.png"] {
                let thumb = try #require(Thumbnailer.thumbnail(from: Fixtures.data(name), pixels: 112), "\(name)")
                #expect(TestImages.inspect(thumb)?.width == 112)
            }
            #expect(Thumbnailer.thumbnail(from: try Fixtures.data("art/broken.jpg"), pixels: 112) == nil)
        }

        private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
            var bytes = [UInt8](repeating: 0, count: 4)
            guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        }
    }

    @MainActor @Suite("PlaybackArtwork")
    struct PlaybackArtworkTests {
        @Test("cuts the centered square out, at full resolution")
        func square() throws {
            let landscape = try #require(PlaybackArtwork.square(from: TestImages.make(width: 600, height: 400)))
            #expect(landscape.width == 400)
            #expect(landscape.height == 400)

            let portrait = try #require(PlaybackArtwork.square(from: TestImages.make(width: 300, height: 500, type: .jpeg)))
            #expect(portrait.width == 300)
            #expect(portrait.height == 300)

            let already = try #require(PlaybackArtwork.square(from: TestImages.make(width: 256, height: 256)))
            #expect(already.width == 256)
        }

        @Test("not an image")
        func notAnImage() {
            #expect(PlaybackArtwork.square(from: Data()) == nil)
            #expect(PlaybackArtwork.square(from: Data("nope".utf8)) == nil)
        }

        @Test("loads the folder image of an album")
        func loadsFolderImage() async throws {
            let dir = try TempDir()
            try dir.write("01.mp3")
            try dir.copy("art/cover.jpg", to: "cover.jpg")
            let image = await PlaybackArtwork.load(directory: dir.url, embeddedFrom: [dir.path("01.mp3")])
            #expect(image?.width == 200)
            #expect(image?.height == 200)
        }

        @Test("a folder image beats embedded art, embedded art beats any other image")
        func priority() async throws {
            let dir = try TempDir()
            try dir.copy("formats/t_cover.mp3", to: "01.mp3")         // embedded: 300x200 -> 200
            try dir.write("big.png", TestImages.make(width: 90, height: 90))
            let embedded = await PlaybackArtwork.load(directory: dir.url, embeddedFrom: [dir.path("01.mp3")])
            #expect(embedded?.width == 200)

            try dir.write("folder.png", TestImages.make(width: 60, height: 60))
            let folder = await PlaybackArtwork.load(directory: dir.url, embeddedFrom: [dir.path("01.mp3")])
            #expect(folder?.width == 60)
        }

        @Test("any image is the last resort; nothing gives nil")
        func lastResort() async throws {
            let dir = try TempDir()
            try dir.copy("formats/t_v23.mp3", to: "01.mp3")
            let none = await PlaybackArtwork.load(directory: dir.url, embeddedFrom: [dir.path("01.mp3")])
            #expect(none == nil)

            try dir.write("scan.png", TestImages.make(width: 90, height: 90))
            let any = await PlaybackArtwork.load(directory: dir.url, embeddedFrom: [dir.path("01.mp3")])
            #expect(any?.width == 90)
        }

        @Test("an undecodable cover is skipped in favour of the next candidate")
        func skipsBroken() async throws {
            let dir = try TempDir()
            try dir.write("cover.jpg", Data("not a jpeg".utf8))
            try dir.write("other.png", TestImages.make(width: 70, height: 70))
            let image = await PlaybackArtwork.load(directory: dir.url, embeddedFrom: [])
            #expect(image?.width == 70)
        }

        @Test("FLAC embedded art")
        func flacEmbedded() async throws {
            let dir = try TempDir()
            try dir.copy("formats/t_cover.flac", to: "01.flac")
            let image = await PlaybackArtwork.load(directory: dir.url, embeddedFrom: [dir.path("01.flac")])
            #expect(image?.width == 200)
        }
    }

    @MainActor @Suite("AlbumArtProcessor")
    struct AlbumArtProcessorTests {
        private func jobs(_ results: [TagReadResult], in directory: String = "/M/A") -> [AlbumArtJob] {
            AlbumArtProcessor.jobs(directory: URL(fileURLWithPath: directory), results: results)
        }

        private func describe(_ candidates: [AlbumArtJob.Candidate]) -> [String] {
            candidates.map {
                switch $0 {
                case .file(let url): "file:" + url.lastPathComponent
                case .embedded(let url): "embedded:" + url.lastPathComponent
                }
            }
        }

        @Test("one job per album of the directory, in order of first appearance")
        func perAlbum() {
            let result = jobs([
                Make.result("/M/A/1.mp3", id: 0, album: "One"),
                Make.result("/M/A/2.mp3", id: 1, album: "Two"),
                Make.result("/M/A/3.mp3", id: 2, album: "one"),
            ])
            #expect(result.map(\.key) == [
                AlbumKey.make(directory: URL(fileURLWithPath: "/M/A"), title: "one"),
                AlbumKey.make(directory: URL(fileURLWithPath: "/M/A"), title: "two"),
            ])
        }

        @Test("results are processed in input order whatever order they arrived in")
        func order() {
            let result = jobs([
                Make.result("/M/A/2.mp3", id: 1, album: "Two", artwork: .embedded),
                Make.result("/M/A/1.mp3", id: 0, album: "One", artwork: .embedded),
            ])
            #expect(result.count == 2)
            #expect(result[0].key.hasSuffix("one"))
        }

        @Test("candidates in priority order: folder cover, embedded, any image")
        func priority() {
            let result = jobs([
                Make.result("/M/A/1.mp3", id: 0, artwork: .anyImage("scan.png")),
                Make.result("/M/A/2.mp3", id: 1, artwork: .embedded),
                Make.result("/M/A/3.mp3", id: 2, artwork: .cover("Cover.jpg")),
            ])
            #expect(describe(result[0].candidates) == ["file:Cover.jpg", "embedded:2.mp3", "file:scan.png"])
        }

        @Test("at most three files are tried for embedded art")
        func embeddedLimit() {
            let result = jobs((0..<6).map { Make.result("/M/A/\($0).mp3", id: $0, artwork: .embedded) })
            #expect(describe(result[0].candidates) == ["embedded:0.mp3", "embedded:1.mp3", "embedded:2.mp3"])
        }

        @Test("an album without art has no candidates")
        func noArt() {
            let result = jobs([Make.result("/M/A/1.mp3", artwork: .none)])
            #expect(result.count == 1)
            #expect(result[0].candidates.isEmpty)
        }

        @Test("unusable files take no part")
        func unusable() {
            let result = jobs([
                Make.result("/M/A/1.mp3", id: 0, status: .failed("x"), album: "Bad"),
                Make.result("/M/A/2.mp3", id: 1, status: .noTags, album: "Bad"),
                Make.result("/M/A/3.mp3", id: 2, album: "Good", artwork: .embedded),
            ])
            #expect(result.count == 1)
            #expect(result[0].key.hasSuffix("good"))
        }

        @Test("loading a folder image and an embedded one")
        func load() async throws {
            let dir = try TempDir()
            let image = try dir.copy("art/cover.jpg", to: "cover.jpg")
            let fromFile = await AlbumArtProcessor.load(.file(image))
            #expect(fromFile == (try Fixtures.data("art/cover.jpg")))

            let mp3 = try dir.copy("formats/t_cover.mp3", to: "a.mp3")
            let mp3Art = try #require(await AlbumArtProcessor.load(.embedded(mp3)))
            #expect(TestImages.inspect(mp3Art)?.width == 300)

            let flac = try dir.copy("formats/t_cover.flac", to: "a.flac")
            let flacArt = try #require(await AlbumArtProcessor.load(.embedded(flac)))
            #expect(TestImages.inspect(flacArt)?.width == 300)

            let m4a = try dir.copy("formats/t_cover.m4a", to: "a.m4a")
            let m4aArt = try #require(await AlbumArtProcessor.load(.embedded(m4a)))
            #expect(TestImages.inspect(m4aArt)?.width == 300)

            #expect(await AlbumArtProcessor.load(.file(dir.path("missing.jpg"))) == nil)
            let plain = try dir.copy("formats/t_v23.mp3", to: "plain.mp3")
            #expect(await AlbumArtProcessor.load(.embedded(plain)) == nil)
        }

        @Test("process caches a thumbnail of the first usable candidate")
        func process() async throws {
            let dir = try TempDir()
            let store = CoverStore(url: dir.path("c.sqlite"), thumbnailPixels: AppConstants.coverThumbnailPixels)
            let cover = try dir.copy("art/portrait.png", to: "cover.png")
            let job = AlbumArtJob(key: "album-1", candidates: [.file(cover)])

            #expect(await AlbumArtProcessor.process(job, into: store))
            let data = try #require(store.data(for: "album-1"))
            let info = try #require(TestImages.inspect(data))
            #expect(info.width == AppConstants.coverThumbnailPixels)
            #expect(info.height == AppConstants.coverThumbnailPixels)
        }

        @Test("broken and missing candidates are skipped")
        func processFallsThrough() async throws {
            let dir = try TempDir()
            let store = CoverStore(url: dir.path("c.sqlite"), thumbnailPixels: AppConstants.coverThumbnailPixels)
            let broken = try dir.copy("art/broken.jpg", to: "cover.jpg")
            let good = try dir.copy("art/square.jpg", to: "other.jpg")
            let job = AlbumArtJob(key: "k", candidates: [.file(dir.path("nope.jpg")), .file(broken), .file(good)])
            #expect(await AlbumArtProcessor.process(job, into: store))
            #expect(store.data(for: "k") != nil)
        }

        @Test("nothing found means nothing cached")
        func processNothing() async throws {
            let dir = try TempDir()
            let store = CoverStore(url: dir.path("c.sqlite"), thumbnailPixels: AppConstants.coverThumbnailPixels)
            let broken = try dir.copy("art/broken.jpg", to: "cover.jpg")
            #expect(await !AlbumArtProcessor.process(AlbumArtJob(key: "none", candidates: []), into: store))
            #expect(await !AlbumArtProcessor.process(AlbumArtJob(key: "bad", candidates: [.file(broken)]), into: store))
            #expect(store.data(for: "none") == nil)
            #expect(store.data(for: "bad") == nil)
        }
    }
}
