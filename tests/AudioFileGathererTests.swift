import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("AudioFileGatherer")
    struct AudioFileGathererTests {
        @Test("supported extensions, case-insensitive")
        func supported() {
            for name in ["a.mp3", "a.MP3", "a.m4a", "a.m4b", "a.aac", "a.flac", "a.ogg", "a.wav", "a.wave",
                         "a.aif", "a.aiff", "a.aifc", "a.caf", "Dir/A.FLAC"] {
                #expect(AudioFileGatherer.isSupported(URL(fileURLWithPath: "/x/" + name)), "\(name)")
            }
            for name in ["a.txt", "a.jpg", "a", "a.opus", "a.oga", "a.wma", "a.ape", "a.wv", "mp3", "a.mp3.bak"] {
                #expect(!AudioFileGatherer.isSupported(URL(fileURLWithPath: "/x/" + name)), "\(name)")
            }
        }

        @Test("walks directories recursively and keeps only audio files")
        func recursive() throws {
            let dir = try TempDir()
            try dir.write("Artist/Album/01.mp3")
            try dir.write("Artist/Album/cover.jpg")
            try dir.write("Artist/Album/notes.txt")
            try dir.write("Artist/Album/Disc 2/01.flac")
            try dir.write("Other/track.ogg")

            let found = AudioFileGatherer.gather(from: [dir.url])
            #expect(dir.relative(found) == [
                "Artist/Album/01.mp3", "Artist/Album/Disc 2/01.flac", "Other/track.ogg",
            ])
        }

        @Test("skips hidden files, hidden directories and package contents")
        func skipsHidden() throws {
            let dir = try TempDir()
            try dir.write("visible.mp3")
            try dir.write(".hidden.mp3")
            try dir.write("._visible.mp3")
            try dir.write(".hiddendir/inside.mp3")
            try dir.write("Some.app/Contents/inside.mp3")

            let found = AudioFileGatherer.gather(from: [dir.url])
            #expect(dir.relative(found) == ["visible.mp3"])
        }

        @Test("explicitly passed files are kept only when supported")
        func explicitFiles() throws {
            let dir = try TempDir()
            let audio = try dir.write("a.mp3")
            let text = try dir.write("a.txt")
            let found = AudioFileGatherer.gather(from: [text, audio])
            #expect(dir.relative(found) == ["a.mp3"])
        }

        @Test("a directory that is itself named like an audio file is not a track")
        func directoryWithAudioExtension() throws {
            let dir = try TempDir()
            try dir.mkdir("album.flac")
            try dir.write("album.flac/01.mp3")
            let found = AudioFileGatherer.gather(from: [dir.url])
            #expect(dir.relative(found) == ["album.flac/01.mp3"])
        }

        @Test("missing paths are ignored")
        func missing() throws {
            let dir = try TempDir()
            let found = AudioFileGatherer.gather(from: [dir.path("nope"), dir.path("nope.mp3")])
            #expect(found.isEmpty)
            #expect(AudioFileGatherer.gather(from: []).isEmpty)
        }

        @Test("duplicates are dropped, whether passed twice or also found in a passed directory")
        func dedupe() throws {
            let dir = try TempDir()
            let file = try dir.write("Album/01.mp3")
            try dir.write("Album/02.mp3")

            let found = AudioFileGatherer.gather(from: [file, dir.path("Album"), file, dir.url])
            #expect(dir.relative(found) == ["Album/01.mp3", "Album/02.mp3"])
        }

        @Test("natural order, one path component at a time")
        func naturalOrder() throws {
            let dir = try TempDir()
            for name in ["Album/10 ten.mp3", "Album/2 two.mp3", "Album/1 one.mp3", "Album/02 b.mp3"] {
                try dir.write(name)
            }
            // A directory sorts as a whole: "Album 2" comes after everything in "Album", although
            // "Album 2/..." < "Album/..." would be true for a plain string comparison of the full paths.
            try dir.write("Album 2/01.mp3")
            try dir.write("album10/01.mp3")
            try dir.write("album9/01.mp3")

            let found = dir.relative(AudioFileGatherer.gather(from: [dir.url]))
            #expect(found == [
                "Album/1 one.mp3", "Album/02 b.mp3", "Album/2 two.mp3", "Album/10 ten.mp3",
                "Album 2/01.mp3", "album9/01.mp3", "album10/01.mp3",
            ])
        }

        @Test("inputs are sorted together, not in the order they were given")
        func sortsAcrossInputs() throws {
            let dir = try TempDir()
            let b = try dir.write("b/01.mp3")
            let a = try dir.write("a/01.mp3")
            #expect(dir.relative(AudioFileGatherer.gather(from: [b, a])) == ["a/01.mp3", "b/01.mp3"])
        }
    }
}
