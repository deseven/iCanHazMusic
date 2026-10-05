// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("TagReader: formats")
    struct TagReaderFormatTests {
        private func read(_ fixture: String, strategy: TagReader.Strategy = .auto, artwork: Bool = false) async throws -> TagReadResult {
            let reader = TagReader(strategy: strategy, concurrency: 2, detectArtwork: artwork)
            return await reader.readOne(url: try Fixtures.url(fixture))
        }

        private func expectFullyTagged(_ r: TagReadResult, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(r.status == .complete, sourceLocation: sourceLocation)
            #expect(r.tags.title == Fixtures.title, sourceLocation: sourceLocation)
            #expect(r.tags.artist == Fixtures.artist, sourceLocation: sourceLocation)
            #expect(r.tags.album == Fixtures.album, sourceLocation: sourceLocation)
            #expect(r.tags.year == Fixtures.year, sourceLocation: sourceLocation)
            #expect(r.tags.trackNumber == Fixtures.trackNumber, sourceLocation: sourceLocation)
            let duration = r.tags.duration ?? 0
            #expect(abs(duration - Fixtures.duration) < 0.25, "duration \(duration)", sourceLocation: sourceLocation)
            #expect(!r.sources.isEmpty, sourceLocation: sourceLocation)
        }

        @Test("every format we support yields complete tags",
              arguments: ["t_v23.mp3", "t_v24.mp3", "t_v22.mp3", "t.flac", "t.ogg", "t_aac.m4a", "t_alac.m4a", "t.caf"])
        func fullyTagged(name: String) async throws {
            expectFullyTagged(try await read("formats/" + name))
        }

        @Test("the same result whichever strategy is used",
              arguments: [TagReader.Strategy.auto, .hybrid, .audioFile, .avFoundation])
        func strategies(strategy: TagReader.Strategy) async throws {
            for name in ["t_v23.mp3", "t.flac", "t_aac.m4a"] {
                let r = try await read("formats/" + name, strategy: strategy)
                #expect(r.status == .complete, "\(name) via \(strategy)")
                #expect(r.tags.title == Fixtures.title, "\(name) via \(strategy)")
            }
        }

        @Test("auto reads MP3 with AVFoundation and FLAC with AudioFile")
        func autoRouting() async throws {
            let mp3 = try await read("formats/t_v23.mp3")
            #expect(mp3.sources == ["AVFoundation"])
            let flac = try await read("formats/t.flac")
            #expect(flac.sources == ["AudioFile"])
        }

        @Test("ID3v1-only files are read too")
        func id3v1Only() async throws {
            let r = try await read("formats/t_v1.mp3")
            #expect(r.status == .complete)
            #expect(r.tags.title == "V1 Title")
            #expect(r.tags.artist == "V1 Artist")
            #expect(r.tags.album == "V1 Album")
            #expect(r.tags.year == "2011")
            #expect(r.tags.trackNumber == 7)
        }

        @Test("WAV carries title and artist only")
        func wav() async throws {
            let r = try await read("formats/t.wav")
            #expect(r.tags.title == Fixtures.title)
            #expect(r.tags.artist == Fixtures.artist)
            #expect(!r.status.isFailure)
        }

        @Test("AIFF is readable")
        func aiff() async throws {
            let r = try await read("formats/t.aiff")
            #expect(!r.status.isFailure)
            #expect(r.tags.title == Fixtures.title)
        }

        @Test("non-ASCII tags survive")
        func unicode() async throws {
            let r = try await read("formats/t_unicode.mp3")
            #expect(r.tags.title == "Тест ☃ 日本語")
            #expect(r.tags.artist == "Björk")
            #expect(r.tags.album == "Ünïcode Album")
        }

        @Test("track 7/12 and a full date")
        func trackOfTotal() async throws {
            let r = try await read("formats/t_track_of_total.mp3")
            #expect(r.tags.trackNumber == 7)
            #expect(r.tags.year == "2019")
        }

        @Test("missing artist falls back to album artist, then composer", arguments: [
            ("t_albumartist.mp3", "TAlbumArtist"), ("t_albumartist.flac", "TAlbumArtist"), ("t_composer.mp3", "TComposer"),
        ])
        func artistFallbacks(name: String, expected: String) async throws {
            let r = try await read("formats/" + name)
            #expect(r.tags.artist == expected)
            #expect(r.status == .complete)
            #expect(r.rawFields[.artist] == nil)
        }

        @Test("partially tagged files list what was replaced by a fallback")
        func partial() async throws {
            let onlyArtist = try await read("formats/t_onlyartist.mp3")
            #expect(onlyArtist.status == .partial(fallbacks: ["title", "album"]))
            #expect(onlyArtist.tags.artist == "OnlyArtist")
            #expect(onlyArtist.tags.title == TagFallback.title)
            #expect(onlyArtist.tags.album == TagFallback.album)

            let onlyTitle = try await read("formats/t_onlytitle.mp3")
            #expect(onlyTitle.status == .partial(fallbacks: ["artist", "album"]))
            #expect(onlyTitle.tags.title == "OnlyTitle")
            #expect(onlyTitle.rawFields[.title] == "OnlyTitle")
            #expect(onlyTitle.rawFields[.artist] == nil)
        }

        @Test("readable files without tags", arguments: ["t_notags.mp3", "t_notags.flac", "plain.mp3"])
        func noTags(name: String) async throws {
            let r = try await read("formats/" + name)
            #expect(r.status == .noTags)
            #expect(r.tags.title == TagFallback.title)
            #expect(r.tags.artist == TagFallback.artist)
            #expect(r.tags.album == TagFallback.album)
            #expect((r.tags.duration ?? 0) > 1)
        }

        @Test("the result carries the index and the url it was asked for")
        func identity() async throws {
            let url = try Fixtures.url("formats/t.flac")
            let r = await TagReader(detectArtwork: false).readOne(index: 7, url: url)
            #expect(r.id == 7)
            #expect(r.url == url)
            #expect(r.elapsed >= 0)
        }
    }

    @MainActor @Suite("TagReader: failures")
    struct TagReaderFailureTests {
        private func failure(_ url: URL) async -> String? {
            let r = await TagReader(detectArtwork: false).readOne(url: url)
            if case .failed(let reason) = r.status { return reason }
            return nil
        }

        @Test("a file that isn't there")
        func missing() async throws {
            let reason = await failure(URL(fileURLWithPath: "/nonexistent/dir/song.mp3"))
            #expect(reason?.hasPrefix("file not found") == true)
        }

        @Test("a folder passed instead of a file")
        func folder() async throws {
            let dir = try TempDir()
            let reason = await failure(dir.url)
            #expect(reason?.hasPrefix("not a file") == true)
        }

        @Test("an empty file", arguments: ["broken/empty.flac"])
        func empty(name: String) async throws {
            let reason = await failure(try Fixtures.url(name))
            #expect(reason?.hasPrefix("file is empty") == true)
        }

        @Test("a file that is not audio at all")
        func garbage() async throws {
            let reason = await failure(try Fixtures.url("broken/garbage.mp3"))
            #expect(reason?.hasPrefix("unrecognised header") == true)
        }

        @Test("a text file that claims to be FLAC")
        func fakeFlac() async throws {
            let dir = try TempDir()
            let file = try dir.write("fake.flac", Data("definitely not a flac".utf8))
            let reason = await failure(file)
            #expect(reason?.hasPrefix("unrecognised header") == true)
        }

        @Test("failed files have fallback tags, no artwork and no sources")
        func failedShape() async throws {
            let r = await TagReader().readOne(url: try Fixtures.url("broken/garbage.mp3"))
            #expect(r.status.isFailure)
            #expect(r.tags.title == TagFallback.title)
            #expect(r.sources.isEmpty)
            #expect(r.artwork == .none)
            #expect(r.rawFields.isEmpty)
        }

        @Test("a video that pretends to be an mp3 is not a complete track")
        func video() async throws {
            let r = await TagReader(detectArtwork: false).readOne(url: try Fixtures.url("broken/video.mp3"))
            #expect(r.status != .complete)
            #expect(!AlbumBuilder.isUsable(r.status))
        }

        @Test("a truncated file is handled without crashing")
        func truncated() async throws {
            let r = await TagReader(detectArtwork: false).readOne(url: try Fixtures.url("broken/truncated.mp3"))
            // Depending on the OS it's either read as far as it goes or reported as failed; never a crash.
            switch r.status {
            case .failed(let reason): #expect(!reason.isEmpty)
            default: #expect(r.tags.title == Fixtures.title)
            }
        }
    }

    @MainActor @Suite("TagReader: streaming")
    struct TagReaderStreamTests {
        private func collect(_ reader: TagReader, _ urls: [URL]) async -> [TagReadResult] {
            var out: [TagReadResult] = []
            for await r in reader.read(urls: urls) { out.append(r) }
            return out
        }

        @Test("every input yields exactly one result, in completion order but with its input index")
        func oneResultPerInput() async throws {
            let names = ["t_v23.mp3", "t.flac", "t_aac.m4a", "t_alac.m4a", "t.ogg", "t_v24.mp3", "t.caf"]
            var urls = try names.map { try Fixtures.url("formats/" + $0) }
            urls.insert(URL(fileURLWithPath: "/nonexistent/x.mp3"), at: 3)

            let results = await collect(TagReader(concurrency: 3, detectArtwork: false), urls)
            #expect(results.count == urls.count)
            #expect(Set(results.map(\.id)) == Set(urls.indices))
            for r in results { #expect(r.url == urls[r.id]) }
            #expect(results.filter { $0.status.isFailure }.map(\.id) == [3])
        }

        @Test("a concurrency of one works, and bad values are clamped")
        func concurrencyOne() async throws {
            let urls = try ["t.flac", "t_v23.mp3", "t_aac.m4a"].map { try Fixtures.url("formats/" + $0) }
            let results = await collect(TagReader(concurrency: 1, detectArtwork: false), urls)
            #expect(results.count == 3)
            #expect(TagReader(concurrency: 0).concurrency == 1)
            #expect(TagReader(concurrency: -4).concurrency == 1)
        }

        @Test("an empty input finishes immediately")
        func empty() async {
            let results = await collect(TagReader(), [])
            #expect(results.isEmpty)
        }

        @Test("paths and urls are equivalent")
        func paths() async throws {
            let url = try Fixtures.url("formats/t.flac")
            var results: [TagReadResult] = []
            for await r in TagReader(detectArtwork: false).read(paths: [url.path]) { results.append(r) }
            #expect(results.count == 1)
            #expect(results[0].tags.title == Fixtures.title)
        }

        @Test("many files, more than the window")
        func manyFiles() async throws {
            let url = try Fixtures.url("formats/t_v23.mp3")
            let dir = try TempDir()
            let urls = try (0..<40).map { try dir.write("\($0).mp3", Data(contentsOf: url)) }
            let results = await collect(TagReader(concurrency: 4, detectArtwork: false), urls)
            #expect(results.count == 40)
            #expect(results.allSatisfy { $0.status == .complete })
        }

        @Test("the default concurrency is sane")
        func defaultConcurrency() {
            #expect(TagReader.defaultConcurrency >= 1)
            #expect(TagReader.defaultConcurrency <= ProcessInfo.processInfo.processorCount)
        }
    }

    @MainActor @Suite("TagReader.offload")
    struct OffloadTests {
        @Test("returns the value")
        func value() async throws {
            let v = try await TagReader.offload(timeout: 5) { 42 }
            #expect(v == 42)
        }

        @Test("propagates errors")
        func error() async {
            struct Boom: Error {}
            await #expect(throws: Boom.self) {
                try await TagReader.offload(timeout: 5) { throw Boom() }
            }
        }

        @Test("gives up waiting after the timeout")
        func timeout() async {
            let started = Date()
            await #expect(throws: TagReadError.self) {
                try await TagReader.offload(timeout: 0.1) { Thread.sleep(forTimeInterval: 1); return 1 }
            }
            #expect(Date().timeIntervalSince(started) < 0.9)
        }
    }

    @MainActor @Suite("TagReader: ID3v1 recovery")
    struct TagReaderTrailingTests {
        private let title = "A Title That Is Definitely Longer Than Thirty Bytes"
        private let artist = "An Artist Whose Name Does Not Fit Either"

        private func make(_ dir: TempDir, name: String = "x.mp3", trailer: Data) throws -> URL {
            try dir.write(name, Fixtures.data("formats/plain.mp3") + trailer)
        }

        @Test("cut-off ID3v1 values are restored from a Lyrics3v2 block")
        func restored() async throws {
            let dir = try TempDir()
            let v1 = Synthetic.id3v1(title: String(title.prefix(30)), artist: String(artist.prefix(30)), album: "Short Album")
            let lyrics = Synthetic.lyrics3([("ETT", title), ("EAR", artist)])
            let file = try make(dir, trailer: lyrics + v1)

            let r = await TagReader(detectArtwork: false).readOne(url: file)
            #expect(r.tags.title == title)
            #expect(r.tags.artist == artist)
            #expect(r.tags.album == "Short Album")
            #expect(r.status == .complete)
        }

        @Test("ID3v1 behind an APEv2 tag is read correctly (AVFoundation alone returns garbage for it)",
              arguments: [TagReader.Strategy.auto, .hybrid, .avFoundation, .audioFile])
        func apeBeforeV1(strategy: TagReader.Strategy) async throws {
            let dir = try TempDir()
            let v1 = Synthetic.id3v1(title: String(title.prefix(30)), artist: "Artist", album: "Album")
            let file = try make(dir, trailer: Synthetic.ape([("Title", title)]) + v1)
            let r = await TagReader(strategy: strategy, detectArtwork: false).readOne(url: file)
            #expect(r.tags.title == title)           // restored from the APE block
            #expect(r.tags.artist == "Artist")
            #expect(r.tags.album == "Album")
            #expect(r.sources == ["AudioFile"])
        }

        @Test("a trailing block that doesn't continue the v1 value is not used")
        func notAPrefix() async throws {
            let dir = try TempDir()
            let v1 = Synthetic.id3v1(title: String(title.prefix(30)), artist: "Artist", album: "Album")
            let file = try make(dir, trailer: Synthetic.lyrics3([("ETT", "Something Unrelated But Rather Long Too")]) + v1)
            let r = await TagReader(detectArtwork: false).readOne(url: file)
            #expect(r.tags.title == String(title.prefix(30)))
        }

        @Test("short ID3v1 values trigger no recovery")
        func shortValues() async throws {
            let dir = try TempDir()
            let v1 = Synthetic.id3v1(title: "Short", artist: "Short", album: "Short")
            let file = try make(dir, trailer: Synthetic.lyrics3([("ETT", "Short, but longer in lyrics3")]) + v1)
            let r = await TagReader(detectArtwork: false).readOne(url: file)
            #expect(r.tags.title == "Short")
        }
    }

    @MainActor @Suite("TagReader: artwork detection")
    struct TagReaderArtworkTests {
        private func detect(_ files: [(fixture: String, name: String)], extra: [String] = [], read name: String,
                            detectArtwork: Bool = true) async throws -> ArtworkSource {
            let dir = try TempDir()
            for f in files { try dir.copy("formats/" + f.fixture, to: f.name) }
            for e in extra { try dir.write(e) }
            return await TagReader(detectArtwork: detectArtwork).readOne(url: dir.path(name)).artwork
        }

        @Test("embedded artwork is found in every container that has it",
              arguments: ["t_cover.mp3", "t_cover.m4a", "t_cover.flac"])
        func embedded(fixture: String) async throws {
            let source = try await detect([(fixture, "a." + (fixture as NSString).pathExtension)], read: "a." + (fixture as NSString).pathExtension)
            #expect(source == .embedded)
        }

        @Test("files without artwork", arguments: ["t_v23.mp3", "t.flac", "t_aac.m4a"])
        func noArtwork(fixture: String) async throws {
            let ext = (fixture as NSString).pathExtension
            let source = try await detect([(fixture, "a." + ext)], read: "a." + ext)
            #expect(source == .none)
        }

        @Test("a cover image next to the file wins over embedded art")
        func folderImageWins() async throws {
            let source = try await detect([("t_cover.mp3", "a.mp3")], extra: ["Cover.JPG", "other.png"], read: "a.mp3")
            #expect(source == .cover("Cover.JPG"))
        }

        @Test("embedded art wins over an arbitrary image")
        func embeddedBeatsAnyImage() async throws {
            let source = try await detect([("t_cover.mp3", "a.mp3")], extra: ["scan.png"], read: "a.mp3")
            #expect(source == .embedded)
        }

        @Test("an arbitrary image is the last resort")
        func anyImage() async throws {
            let source = try await detect([("t_v23.mp3", "a.mp3")], extra: ["scan 10.png", "scan 2.jpg"], read: "a.mp3")
            #expect(source == .anyImage("scan 2.jpg"))
        }

        @Test("a failed read has no artwork, even with a cover next to it")
        func failed() async throws {
            let dir = try TempDir()
            try dir.write("cover.jpg")
            let file = try dir.write("bad.mp3", Data("garbage".utf8))
            let r = await TagReader().readOne(url: file)
            #expect(r.status.isFailure)
            #expect(r.artwork == .none)
        }

        @Test("detection can be switched off")
        func disabled() async throws {
            let source = try await detect([("t_cover.mp3", "a.mp3")], extra: ["cover.jpg"], read: "a.mp3", detectArtwork: false)
            #expect(source == .none)
        }

        @Test("labels")
        func labels() {
            #expect(ArtworkSource.cover("cover.jpg").label == "cover.jpg")
            #expect(ArtworkSource.anyImage("x.png").label == "x.png")
            #expect(ArtworkSource.embedded.label == "embedded")
            #expect(ArtworkSource.none.label == "")
        }
    }
}
