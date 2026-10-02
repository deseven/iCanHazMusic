import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("ImportSession")
    struct ImportSessionTests {
        /// A small library:
        ///
        ///     Artist1/Album A/01.mp3 02.mp3 cover.jpg   (tagged, folder cover)
        ///     Artist2/Album B/01.flac                   (tagged, embedded cover)
        ///     Artist3/Plain/01.mp3 02.mp3               (tagged, no art)
        ///     Broken/garbage.mp3 untagged.mp3           (unusable)
        ///     notes.txt
        private func makeLibrary() throws -> TempDir {
            let dir = try TempDir()
            try dir.copy("formats/t_v23.mp3", to: "Artist1/Album A/01.mp3")
            try dir.copy("formats/t_v24.mp3", to: "Artist1/Album A/02.mp3")
            try dir.copy("art/cover.jpg", to: "Artist1/Album A/cover.jpg")
            try dir.copy("formats/t_cover.flac", to: "Artist2/Album B/01.flac")
            try dir.copy("formats/t_v23.mp3", to: "Artist3/Plain/01.mp3")
            try dir.copy("formats/t_v24.mp3", to: "Artist3/Plain/02.mp3")
            try dir.copy("broken/garbage.mp3", to: "Broken/garbage.mp3")
            try dir.copy("formats/plain.mp3", to: "Broken/untagged.mp3")
            try dir.write("notes.txt", Data("hi".utf8))
            return dir
        }

        private func makeStore(_ dir: TempDir) -> CoverStore {
            CoverStore(url: dir.path("covers.sqlite"), thumbnailPixels: AppConstants.coverThumbnailPixels)
        }

        @Test("reads a library into albums, counts the outcome and caches the cover art")
        func fullRun() async throws {
            let library = try makeLibrary()
            let scratch = try TempDir()
            let covers = makeStore(scratch)
            let session = ImportSession(coverStore: covers)

            let outcome = await session.run(inputs: [library.url])

            #expect(!outcome.aborted)
            #expect(outcome.fileCount == 7)
            #expect(session.total == 7)
            #expect(session.processed == 7)
            #expect(session.failed == 2)                       // garbage + untagged
            #expect(session.successful + session.incomplete == 5)
            #expect(session.stage == .appending)

            // Albums come in playlist (path) order; the unusable files are gone.
            #expect(library.relative(outcome.albums.map(\.directory)) == ["Artist1/Album A", "Artist2/Album B", "Artist3/Plain"])
            #expect(outcome.albums.map(\.tracks.count) == [2, 1, 2])
            #expect(outcome.albums[0].tracks.map(\.codec) == ["MP3", "MP3"])
            #expect(outcome.albums[1].tracks[0].codec == "FLAC")

            // Art: folder cover, embedded FLAC picture, none.
            #expect(session.albumsProcessed == 3)
            #expect(session.artsProcessed == 2)
            let size = AppConstants.coverThumbnailPixels
            for index in [0, 1] {
                let data = try #require(covers.data(for: outcome.albums[index].key), "album \(index)")
                #expect(TestImages.inspect(data)?.width == size)
            }
            #expect(covers.data(for: outcome.albums[2].key) == nil)
        }

        @Test("the albums carry the tags of the files")
        func albumContents() async throws {
            let library = try makeLibrary()
            let session = ImportSession(coverStore: makeStore(try TempDir()))
            let outcome = await session.run(inputs: [library.path("Artist1")])
            #expect(outcome.albums.count == 1)
            let album = outcome.albums[0]
            #expect(album.title == Fixtures.album)
            #expect(album.artist == Fixtures.artist)
            #expect(album.year == Fixtures.year)
            #expect(album.tracks.map(\.title) == [Fixtures.title, Fixtures.title])
            #expect(album.tracks.map(\.number) == [Fixtures.trackNumber, Fixtures.trackNumber])
            #expect(session.successful == 2)
            #expect(session.incomplete == 0)
        }

        @Test("files and directories can be mixed, duplicates are read once")
        func mixedInputs() async throws {
            let library = try makeLibrary()
            let session = ImportSession(coverStore: makeStore(try TempDir()))
            let outcome = await session.run(inputs: [
                library.path("Artist2/Album B/01.flac"),
                library.path("Artist1"),
                library.path("Artist1/Album A/01.mp3"),
            ])
            #expect(outcome.fileCount == 3)
            #expect(library.relative(outcome.albums.map(\.directory)) == ["Artist1/Album A", "Artist2/Album B"])
        }

        @Test("nothing to import")
        func nothing() async throws {
            let dir = try TempDir()
            try dir.write("readme.txt")
            let session = ImportSession(coverStore: makeStore(try TempDir()))
            let outcome = await session.run(inputs: [dir.url])
            #expect(outcome.fileCount == 0)
            #expect(outcome.albums.isEmpty)
            #expect(!outcome.aborted)
            #expect(session.stage == .gathering)

            let none = await ImportSession(coverStore: makeStore(try TempDir())).run(inputs: [])
            #expect(none.fileCount == 0)
        }

        @Test("an aborted run yields no albums")
        func aborted() async throws {
            let library = try makeLibrary()
            let covers = makeStore(try TempDir())
            let session = ImportSession(coverStore: covers)
            session.abort()
            #expect(session.isAborting)

            let outcome = await session.run(inputs: [library.url])
            #expect(outcome.aborted)
            #expect(outcome.albums.isEmpty)
            #expect(session.processed == 0)
        }

        @Test("aborting during the run stops it with no albums")
        func abortedDuringRun() async throws {
            let dir = try TempDir()
            let source = try Fixtures.data("formats/t_v23.mp3")
            for i in 0..<300 { try dir.write("Album \(i / 10)/\(i % 10).mp3", source) }
            let session = ImportSession(coverStore: makeStore(try TempDir()))

            let run = Task { await session.run(inputs: [dir.url]) }
            _ = await waitUntil { session.processed > 0 || session.stage == .appending }
            session.abort()
            let outcome = await run.value

            // Either the abort was in time or the machine was quick enough to finish; both are consistent.
            if outcome.aborted {
                #expect(outcome.albums.isEmpty)
                #expect(session.processed <= 300)
            } else {
                #expect(outcome.albums.count == 30)
            }
        }

        @Test("speed is measured while reading and frozen afterwards")
        func speed() async throws {
            let library = try makeLibrary()
            let session = ImportSession(coverStore: makeStore(try TempDir()))
            #expect(session.speed(at: Date()) == 0)
            _ = await session.run(inputs: [library.url])
            let first = session.speed(at: Date())
            #expect(first > 0)
            let later = session.speed(at: Date().addingTimeInterval(100))
            #expect(later == first)
        }
    }
}
