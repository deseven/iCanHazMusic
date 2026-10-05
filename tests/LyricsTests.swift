// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    // MARK: - Model

    @MainActor @Suite("Lyrics: model and LRC")
    struct LyricsModelTests {
        @Test("timed lines come out in time order; several timestamps, metadata, enhanced tags and fractions are understood")
        func parseLRC() {
            let text = """
            [ar:Someone]
            [ti:Song]
            [00:12.50] second
            [00:05.00]first
            [01:00][00:30.5]twice
            [00:40.00]<00:40.10>en<00:40.50>hanced
            [00:41.123]millis
            [02:00.00]
            not a timed line
            """
            #expect(LRC.parse(text) == [
                LyricLine(time: 5, text: "first"),
                LyricLine(time: 12.5, text: "second"),
                LyricLine(time: 30.5, text: "twice"),
                LyricLine(time: 40, text: "enhanced"),
                LyricLine(time: 41.123, text: "millis"),
                LyricLine(time: 60, text: "twice"),
                LyricLine(time: 120, text: ""),
            ])
        }

        @Test("an offset moves every line, never before the start")
        func offset() {
            #expect(LRC.parse("[offset:500]\n[00:10.00]a\n[00:00.20]b").map(\.time) == [0, 9.5])
            #expect(LRC.parse("[offset:-1000]\n[00:10.00]a").map(\.time) == [11])
        }

        @Test("text that isn't LRC has no lines")
        func notLRC() {
            #expect(LRC.parse("Just words\n[chorus]\nmore words [00:12]").isEmpty)
            #expect(LRC.parse("[ar:A]\n[ti:B]").isEmpty)
            #expect(LRC.parse("").isEmpty)
        }

        @Test("the line being sung is the last one that has started")
        func lineIndex() throws {
            let lyrics = try #require(Lyrics(source: .lrclib, plain: nil, lrc: "[00:05.00]a\n[00:10.00]b\n[00:10.00]c\n[00:20.00]d"))
            #expect(lyrics.lineIndex(at: 0) == nil)
            #expect(lyrics.lineIndex(at: 4.99) == nil)
            #expect(lyrics.lineIndex(at: 5) == 0)
            #expect(lyrics.lineIndex(at: 9.9) == 0)
            #expect(lyrics.lineIndex(at: 10) == 2)
            #expect(lyrics.lineIndex(at: 1000) == 3)
        }

        @Test("lyrics from a file: plain text stays as it is, line breaks are normalised, blank space around is dropped")
        func embeddedPlain() throws {
            let lyrics = try #require(Lyrics.embedded("\r\n  Line one\r\nLine two\rLine three\n\n"))
            #expect(lyrics.source == .embedded)
            #expect(lyrics.plain == "Line one\nLine two\nLine three")
            #expect(!lyrics.isSynced && lyrics.lrc == nil && lyrics.lines.isEmpty)
        }

        @Test("an LRC text in the lyrics tag of a file is synchronised lyrics, with plain text made from it")
        func embeddedLRC() throws {
            let lyrics = try #require(Lyrics.embedded("[ar:A]\n[00:01.00]one\n[00:02.00]two"))
            #expect(lyrics.isSynced)
            #expect(lyrics.plain == "one\ntwo")
            #expect(lyrics.lines.count == 2)
            // One timestamp is not enough to tell lyrics from a line that happens to start with one.
            #expect(try #require(Lyrics.embedded("[00:01.00]one")).isSynced == false)
        }

        @Test("nothing, blank space and too much are no lyrics")
        func noLyrics() {
            #expect(Lyrics.embedded("") == nil)
            #expect(Lyrics.embedded(" \n\t ") == nil)
            #expect(Lyrics.embedded(String(repeating: "x", count: Lyrics.maxBytes + 1)) == nil)
            #expect(Lyrics(source: .lrclib, plain: nil, lrc: nil) == nil)
            #expect(Lyrics(source: .lrclib, plain: "", lrc: "[00:01.00]") == nil)
        }

        @Test("the key ignores case and the blank space around, and tells apart what is different")
        func key() {
            let key = LyricsKey.make(artist: "Artist", title: "Title", album: "Album")
            #expect(key.count == 64 && key.allSatisfy(\.isHexDigit))
            #expect(key == LyricsKey.make(artist: " ARTIST", title: "title ", album: "album\n"))
            #expect(key != LyricsKey.make(artist: "Artist", title: "Title", album: "Other"))
            #expect(key != LyricsKey.make(artist: "Artist", title: "Other", album: "Album"))
            #expect(LyricsKey.make(artist: "a b", title: "c", album: "") != LyricsKey.make(artist: "a", title: "b c", album: ""))
            #expect(key == "146d103f89ec03bcbfc613eaac77fa8dc5568feab91beaec5ce44473270a7166")     // SHA-256, so it is stable
        }

        @Test("a track needs an artist and a title of its own")
        func identified() {
            #expect(TagFallback.isIdentified(artist: "A", title: "B"))
            #expect(!TagFallback.isIdentified(artist: TagFallback.artist, title: "B"))
            #expect(!TagFallback.isIdentified(artist: "A", title: TagFallback.title))
            #expect(LRCLIBTestData.track().hasTags)
            #expect(!LRCLIBTestData.track(artist: TagFallback.artist).hasTags)
        }
    }

    // MARK: - Store

    @MainActor @Suite("Lyrics store")
    struct LyricsStoreTests {
        private let synced = "[00:01.00]one\n[00:02.00]two"

        @Test("lyrics are stored under their key, and come back with their source, text and synchronised text")
        func roundTrip() throws {
            let dir = try TempDir()
            let store = LyricsStore(url: dir.path("cache/lyrics.sqlite"))     // the directory is created
            #expect(store.lyrics(for: "k") == nil && !store.contains("k"))

            let plain = try #require(Lyrics.embedded("Line one\nLine ünï ☃"))
            let timed = try #require(Lyrics(source: .lrclib, plain: "plain", lrc: synced))
            #expect(store.store(plain, for: "a"))
            #expect(store.store(timed, for: "b"))

            #expect(store.lyrics(for: "a") == plain)
            #expect(store.lyrics(for: "b") == timed)
            #expect(store.lyrics(for: "b")?.lrc == synced)
            #expect(store.contains("a") && store.contains("b") && !store.contains("c"))
        }

        @Test("it survives a restart")
        func persistence() throws {
            let url = try TempDir().path("lyrics.sqlite")
            let lyrics = try #require(Lyrics.embedded("text"))
            LyricsStore(url: url).store(lyrics, for: "k")
            #expect(LyricsStore(url: url).lyrics(for: "k") == lyrics)
        }

        @Test("storing replaces what is there, unless told not to")
        func replacing() throws {
            let store = LyricsStore(url: try TempDir().path("lyrics.sqlite"))
            let embedded = try #require(Lyrics.embedded("from the file"))
            let online = try #require(Lyrics(source: .lrclib, plain: "from LRCLIB", lrc: synced))

            #expect(store.store(online, for: "k", replacing: false))
            #expect(store.lyrics(for: "k") == online)
            #expect(store.store(embedded, for: "k"))
            #expect(store.lyrics(for: "k") == embedded)
            #expect(store.lyrics(for: "k")?.lrc == nil)                         // the synchronised text went with it

            #expect(!store.store(online, for: "k", replacing: false))
            #expect(store.lyrics(for: "k") == embedded)
        }

        @Test("a store that can't be opened finds nothing and takes nothing, without failing")
        func broken() throws {
            let dir = try TempDir()
            try dir.write("blocker", Data("a file where a directory should be".utf8))
            let store = LyricsStore(url: dir.path("blocker/lyrics.sqlite"))
            let lyrics = try #require(Lyrics.embedded("text"))
            #expect(!store.store(lyrics, for: "k"))
            #expect(store.lyrics(for: "k") == nil && !store.contains("k"))
        }
    }

    // MARK: - Tags

    @MainActor @Suite("Lyrics in tags")
    struct LyricsTagTests {
        private func read(_ fixture: String, strategy: TagReader.Strategy = .auto) async throws -> TagReadResult {
            await TagReader(strategy: strategy, concurrency: 2, detectArtwork: false).readOne(url: try Fixtures.url("formats/" + fixture))
        }

        @Test("every format that can carry lyrics yields them",
              arguments: ["l_v24.mp3", "l.flac", "l_unsynced.flac", "l.ogg", "l_aac.m4a", "l_alac.m4a", "l.caf"])
        func lyrics(name: String) async throws {
            let r = try await read(name)
            #expect(r.status == .complete)
            #expect(r.tags.lyrics == Fixtures.lyrics)
            #expect(r.tags.title == Fixtures.title && r.tags.artist == Fixtures.artist)
        }

        @Test("whichever strategy reads the file", arguments: [TagReader.Strategy.auto, .hybrid, .audioFile, .avFoundation])
        func strategies(strategy: TagReader.Strategy) async throws {
            for name in ["l_v24.mp3", "l.flac", "l_aac.m4a"] {
                #expect(try await read(name, strategy: strategy).tags.lyrics == Fixtures.lyrics, "\(name) via \(strategy)")
            }
        }

        @Test("files without lyrics have none, and the backends credited are the same as before")
        func none() async throws {
            for name in ["t_v23.mp3", "t.flac", "t_aac.m4a", "t.caf", "t.wav", "t_v1.mp3", "plain.mp3"] {
                #expect(try await read(name).tags.lyrics == nil, "\(name)")
            }
            #expect(try await read("l.flac").sources == ["AudioFile"])
            #expect(try await read("l_v24.mp3").sources == ["AVFoundation"])
        }

        @Test("the Vorbis comments of FLAC are searched for either name, in any case")
        func vorbisComments() {
            func block(_ entries: [String]) -> Data {
                var d = Data.le32(6) + Data.ascii("vendor") + Data.le32(entries.count)
                for entry in entries { d += Data.le32(entry.utf8.count) + Data.ascii(entry) }
                return d
            }
            #expect(FlacComments.lyrics(inComments: block(["TITLE=x", "lyrics=one\ntwo", "ARTIST=y"])) == "one\ntwo")
            #expect(FlacComments.lyrics(inComments: block(["UnsyncedLyrics=text = with equals"])) == "text = with equals")
            #expect(FlacComments.lyrics(inComments: block(["TITLE=x", "LYRICSX=no", "noequals"])) == nil)
            #expect(FlacComments.lyrics(inComments: block([])) == nil)
            #expect(FlacComments.lyrics(inComments: Data.le32(1000) + Data.ascii("cut")) == nil)      // truncated
            #expect(FlacComments.lyrics(inComments: Data()) == nil)
        }
    }

    // MARK: - Import

    @MainActor @Suite("Lyrics on import")
    struct LyricsImportTests {
        private struct Env {
            let session: ImportSession
            let lyrics: LyricsStore
        }

        private func makeEnv() throws -> Env {
            let scratch = try TempDir()
            let covers = CoverStore(url: scratch.path("covers.sqlite"), thumbnailPixels: AppConstants.coverThumbnailPixels)
            let lyrics = LyricsStore(url: scratch.path("lyrics.sqlite"))
            return Env(session: ImportSession(coverStore: covers, lyricsStore: lyrics), lyrics: lyrics)
        }

        private let key = LyricsKey.make(artist: Fixtures.artist, title: Fixtures.title, album: Fixtures.album)

        @Test("lyrics found in the tags are put into the store under artist, title and album")
        func stored() async throws {
            let env = try makeEnv()
            let dir = try TempDir()
            try dir.copy("formats/l.flac", to: "a/01.flac")
            try dir.copy("formats/t_v23.mp3", to: "a/02.mp3")
            let outcome = await env.session.run(inputs: [dir.url])

            #expect(outcome.fileCount == 2)
            #expect(env.session.lyricsFound == 1)
            let lyrics = try #require(env.lyrics.lyrics(for: key))
            #expect(lyrics.source == .embedded && lyrics.plain == Fixtures.lyrics)
        }

        @Test("reading the tags again brings the lyrics of the file back, over what was there")
        func reload() async throws {
            let env = try makeEnv()
            let dir = try TempDir()
            let file = try dir.copy("formats/l_v24.mp3", to: "01.mp3")
            let online = try #require(Lyrics(source: .lrclib, plain: "from LRCLIB", lrc: nil))
            env.lyrics.store(online, for: key)

            let outcome = await env.session.reload(files: [file])
            #expect(!outcome.aborted && env.session.lyricsFound == 1)
            #expect(env.lyrics.lyrics(for: key)?.source == .embedded)
            #expect(env.lyrics.lyrics(for: key)?.plain == Fixtures.lyrics)
        }

        @Test("a file without an artist has no identity to keep lyrics under")
        func noArtist() async throws {
            let env = try makeEnv()
            let dir = try TempDir()
            try dir.copy("formats/l_noartist.flac", to: "01.flac")
            _ = await env.session.run(inputs: [dir.url])
            #expect(env.session.lyricsFound == 0)
            #expect(!env.lyrics.contains(LyricsKey.make(artist: TagFallback.artist, title: Fixtures.title, album: Fixtures.album)))
        }

        @Test("LRC text in a file's lyrics tag is kept as synchronised lyrics")
        func embeddedLRC() throws {
            let lyrics = try #require(Lyrics.embedded("[00:01.00]one\n[00:02.00]two"))
            let store = LyricsStore(url: try TempDir().path("lyrics.sqlite"))
            store.store(lyrics, for: "k")
            #expect(store.lyrics(for: "k")?.isSynced == true)
            #expect(store.lyrics(for: "k")?.source == .embedded)
        }
    }

    // MARK: - Service

    @MainActor @Suite("Lyrics service")
    struct LyricsServiceTests {
        private struct Env {
            let config: ConfigStore
            let store: LyricsStore
            let transport: HTTPStub
            let sleeps: SleepRecorder
            let service: LyricsService
        }

        private static let synced = "[00:01.00]one\n[00:02.00]two"

        private func makeEnv(enabled: Bool = true, transport: HTTPStub? = nil) throws -> Env {
            let dir = try TempDir()
            let config = ConfigStore(paths: AppPaths(workDir: dir.path("work")), saveDelay: .seconds(60))
            if enabled { config.update { $0.integrations.lrclib.enabled = true } }
            let store = LyricsStore(url: dir.path("lyrics.sqlite"))
            let transport = transport ?? HTTPStub(always: LRCLIBAnswer.records([LRCLIBAnswer.record(plain: "online", synced: Self.synced)]))
            let sleeps = SleepRecorder()
            let service = LyricsService(configStore: config, store: store, transport: transport, spacing: .zero, sleep: sleeps.sleep)
            return Env(config: config, store: store, transport: transport, sleeps: sleeps, service: service)
        }

        private let track = LRCLIBTestData.track()
        private var key: String { LyricsKey.make(artist: track.artist, title: track.title, album: track.album) }

        @Test("off by default, and the setting is kept in the config")
        func setting() throws {
            let env = try makeEnv(enabled: false)
            #expect(!env.service.isLRCLIBEnabled)
            #expect(AppConfig().integrations.lrclib.enabled == false)

            env.service.isLRCLIBEnabled = true
            #expect(env.config.config.integrations.lrclib.enabled)
            env.service.isLRCLIBEnabled = false
            #expect(!env.config.config.integrations.lrclib.enabled)

            let data = try #require(ConfigStore.encode(AppConfig()))
            let json = String(decoding: data, as: UTF8.self)
            #expect(json.contains("\"lrclib\"") && json.contains("\"enabled\" : false"))
        }

        @Test("the lyrics a track has in the store are there from the start, and LRCLIB isn't asked")
        func stored() async throws {
            let env = try makeEnv()
            let embedded = try #require(Lyrics.embedded("from the file"))
            env.store.store(embedded, for: key)

            env.service.trackDidStart(track)
            #expect(env.service.current == embedded)
            #expect(env.service.currentKey == key)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.isEmpty)

            env.service.trackDidEnd(track, playedSeconds: 10)
            #expect(env.service.current == nil && env.service.currentKey == nil)
        }

        @Test("without LRCLIB nothing is asked, and a track without lyrics shows none")
        func disabled() async throws {
            let env = try makeEnv(enabled: false)
            env.service.trackDidStart(track)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.service.current == nil)
            #expect(env.transport.requests.isEmpty)
        }

        @Test("with LRCLIB, a track that has none is looked up; what is found is shown at once, and kept")
        func lookup() async throws {
            let env = try makeEnv()
            env.service.trackDidStart(track)
            #expect(await waitUntil { env.service.current != nil })

            let lyrics = try #require(env.service.current)
            #expect(lyrics.source == .lrclib && lyrics.plain == "online" && lyrics.isSynced)
            #expect(env.store.lyrics(for: key) == lyrics)
            #expect(env.transport.requests.count == 1)
            let request = env.transport.requests[0]
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent)
            #expect(HTTPStub.query(of: request) == ["track_name": "Title", "artist_name": "Artist"])

            // Next time it comes from the store.
            env.service.trackDidEnd(track, playedSeconds: 10)
            env.service.trackDidStart(track)
            #expect(env.service.current == lyrics)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.count == 1)
        }

        @Test("without lyrics support nothing is shown or looked up, and what the user chose for LRCLIB is kept")
        func lyricsSupportOff() async throws {
            let env = try makeEnv(transport: HTTPStub(always: LRCLIBAnswer.records([LRCLIBAnswer.record(title: "Other", plain: "online")])))
            #expect(env.service.isEnabled && env.service.isLRCLIBActive)
            #expect(AppConfig().general.lyricsSupport)
            let embedded = try #require(Lyrics.embedded("from the file"))
            env.store.store(embedded, for: key)

            env.service.isEnabled = false
            #expect(!env.config.config.general.lyricsSupport)
            #expect(env.service.isLRCLIBEnabled && !env.service.isLRCLIBActive)
            #expect(env.config.config.integrations.lrclib.enabled)

            env.service.trackDidStart(track)
            #expect(env.service.current == nil)
            #expect(env.service.lyrics(artist: "Artist", title: "Title", album: "Album") == nil)
            #expect(!env.service.hasLyrics(artist: "Artist", title: "Title", album: "Album"))
            env.service.trackDidEnd(track, playedSeconds: 10)

            let other = LRCLIBTestData.track(title: "Other")
            env.service.trackDidStart(other)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.isEmpty)
            env.service.trackDidEnd(other, playedSeconds: 10)

            // The lyrics of the file are in the store all along; with support back on they show up.
            env.service.trackDidStart(track)
            env.service.isEnabled = true
            #expect(env.service.current == embedded)
            #expect(env.service.hasLyrics(artist: "Artist", title: "Title", album: "Album"))
            env.service.trackDidEnd(track, playedSeconds: 10)

            // Turned on during a track without lyrics: LRCLIB is asked then.
            env.service.isEnabled = false
            env.service.trackDidStart(other)
            env.service.isEnabled = true
            #expect(await waitUntil { env.service.current != nil })
            #expect(env.transport.requests.count == 1)
        }

        @Test("turning lyrics support off hides the lyrics of the playing track")
        func lyricsSupportOffWhilePlaying() throws {
            let env = try makeEnv(enabled: false)
            let embedded = try #require(Lyrics.embedded("from the file"))
            env.store.store(embedded, for: key)
            env.service.trackDidStart(track)
            #expect(env.service.current == embedded)

            env.service.isEnabled = false
            #expect(env.service.current == nil)
            env.service.isEnabled = true
            #expect(env.service.current == embedded)
        }

        @Test("tracks without tags are never looked up")
        func untagged() async throws {
            let env = try makeEnv()
            for untagged in [LRCLIBTestData.track(artist: TagFallback.artist), LRCLIBTestData.track(title: TagFallback.title)] {
                env.service.trackDidStart(untagged)
                #expect(env.service.current == nil && env.service.currentKey == nil)
                env.service.trackDidEnd(untagged, playedSeconds: 10)
            }
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.isEmpty)
            #expect(env.service.lyrics(artist: TagFallback.artist, title: "Title", album: "Album") == nil)
            #expect(!env.service.hasLyrics(artist: "Artist", title: TagFallback.title, album: "Album"))
        }

        @Test("a no from LRCLIB is remembered, a failure is not")
        func askedOnce() async throws {
            let answers = LockedBox<[HTTPAnswer]>([LRCLIBAnswer.none])
            let env = try makeEnv(transport: HTTPStub { _, index in
                answers.value[min(index, answers.value.count - 1)]
            })
            env.service.trackDidStart(track)
            #expect(await waitUntil { env.transport.requests.count == 1 })
            try? await Task.sleep(for: .milliseconds(30))
            env.service.trackDidEnd(track, playedSeconds: 10)
            env.service.trackDidStart(track)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(env.transport.requests.count == 1)
            #expect(env.service.current == nil)

            // Another track, for which the answer is a failure on every try.
            let other = LRCLIBTestData.track(title: "Other")
            answers.value = [LRCLIBAnswer.serverError]
            env.service.trackDidStart(other)
            #expect(await waitUntil { env.transport.requests.count == 1 + LRCLIBQueue.maxAttempts })
            try? await Task.sleep(for: .milliseconds(30))

            env.service.trackDidEnd(other, playedSeconds: 10)
            answers.value = [LRCLIBAnswer.records([LRCLIBAnswer.record(title: "Other", plain: "now it works")])]
            env.service.trackDidStart(other)
            #expect(await waitUntil { env.service.current?.plain == "now it works" })
        }

        @Test("only exact matches are taken")
        func exactOnly() async throws {
            let env = try makeEnv(transport: HTTPStub(always: LRCLIBAnswer.records([
                LRCLIBAnswer.record(artist: "Artist feat. Somebody"),
                LRCLIBAnswer.record(duration: 400),
            ])))
            env.service.trackDidStart(track)
            #expect(await waitUntil { env.transport.requests.count == 1 })
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.service.current == nil)
            #expect(!env.store.contains(key))
        }

        @Test("the lyrics of the file win over what LRCLIB brings meanwhile")
        func embeddedWins() async throws {
            let dir = try TempDir()
            let store = LyricsStore(url: dir.path("lyrics.sqlite"))
            let embedded = try #require(Lyrics.embedded("from the file"))
            let key = self.key
            let transport = HTTPStub { _, _ in
                store.store(embedded, for: key)                                 // the tags were read while it was on its way
                return LRCLIBAnswer.records([LRCLIBAnswer.record(plain: "online")])
            }
            let config = ConfigStore(paths: AppPaths(workDir: dir.path("work")), saveDelay: .seconds(60))
            config.update { $0.integrations.lrclib.enabled = true }
            let service = LyricsService(configStore: config, store: store, transport: transport, spacing: .zero)

            service.trackDidStart(track)
            #expect(await waitUntil { service.current != nil })
            #expect(service.current == embedded)
            #expect(store.lyrics(for: key) == embedded)
        }

        @Test("lyrics that arrive for a track that is not playing any more are kept, not shown")
        func late() async throws {
            let open = LockedBox(false)
            let env = try makeEnv(transport: HTTPStub { _, _ in
                while !open.value { try await Task.sleep(for: .milliseconds(5)) }
                return LRCLIBAnswer.records([LRCLIBAnswer.record(plain: "online")])
            })
            env.service.trackDidStart(track)
            #expect(await waitUntil { env.transport.requests.count == 1 })
            env.service.trackDidEnd(track, playedSeconds: 1)
            let next = LRCLIBTestData.track(title: "Next")
            env.service.trackDidStart(next)

            open.value = true
            #expect(await waitUntil { env.store.contains(self.key) })
            #expect(env.service.current == nil)
            #expect(env.service.currentKey == LyricsKey.make(artist: "Artist", title: "Next", album: "Album"))
        }

        @Test("turning LRCLIB on while a track without lyrics plays looks it up; turning it off stops asking")
        func toggling() async throws {
            let env = try makeEnv(enabled: false)
            env.service.trackDidStart(track)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.isEmpty)

            env.service.isLRCLIBEnabled = true
            #expect(await waitUntil { env.service.current != nil })

            env.service.isLRCLIBEnabled = false
            env.service.trackDidEnd(track, playedSeconds: 1)
            env.service.trackDidStart(LRCLIBTestData.track(title: "Another"))
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.count == 1)
        }

        @Test("lyrics of any track can be asked for by artist, title and album")
        func anyTrack() throws {
            let env = try makeEnv()
            let lyrics = try #require(Lyrics.embedded("text"))
            env.store.store(lyrics, for: key)
            #expect(env.service.lyrics(artist: "artist", title: "TITLE", album: " Album ") == lyrics)
            #expect(env.service.hasLyrics(artist: "Artist", title: "Title", album: "Album"))
            #expect(!env.service.hasLyrics(artist: "Artist", title: "Title", album: "Other"))
        }

        @Test("when the tags of the playing track are read again, its lyrics are looked at again")
        func refresh() throws {
            let env = try makeEnv(enabled: false)
            env.service.trackDidStart(track)
            #expect(env.service.current == nil)
            let lyrics = try #require(Lyrics.embedded("new"))
            env.store.store(lyrics, for: key)
            env.service.refreshCurrent()
            #expect(env.service.current == lyrics)
        }
    }
}

/// A value that is read and written from different threads.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
