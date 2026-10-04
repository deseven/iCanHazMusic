import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// The playlist logic of playback (which track follows which, what the playback block shows), running on an
    /// offline engine and a store of its own.
    @MainActor @Suite("PlaybackState")
    struct PlaybackStateTests {
        private static let slice = PlaybackEngine.renderSlice

        /// A store with a playlist, a `PlaybackState` on an offline engine, and the rig to drive it.
        @MainActor private struct Env {
            let dir: TempDir
            let store: PlaylistStore
            let rig: EngineRig
            let state: PlaybackState

            var engine: PlaybackEngine { rig.engine }

            /// Output frame `i` is the first sample of the track starting after `tracks`.
            func start(_ tracks: [RampFile]) -> Int { tracks.reduce(0) { $0 + $1.frames } }

            /// Renders `frames` and refreshes what the playback block would show.
            func run(_ frames: Int) async throws {
                try await rig.render(frames)
                state.tick()
            }
        }

        private func entry(_ file: RampFile, title: String, album: String, track: Int, year: String? = nil) throws -> TrackEntry {
            Make.entry(try file.url().path, artist: "Artist \(album)", album: album, title: title, track: track, year: year)
        }

        private func makeEnv(_ entries: [TrackEntry], lookahead: Double = 60, positionStep: Double = 0,
                             listener: PlaybackListener? = nil) async throws -> Env {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            let store = PlaylistStore(paths: paths, configStore: config)
            #expect(await waitUntil { !store.isLoading })
            await store.append(Make.albums(entries), to: "main")
            let rig = EngineRig(lookahead: lookahead)
            let state = PlaybackState(store: store, engine: rig.engine, tickInterval: nil, positionStep: positionStep,
                                      listener: listener)
            state.volume = 1        // the app's default is 0.7; the tests compare against the files' samples
            // The state is the engine's listener now; keep recording what the engine reports.
            let listener = rig.engine.onEvent
            rig.engine.onEvent = { [weak rig] event in
                rig?.record(event)
                listener?(event)
            }
            return Env(dir: dir, store: store, rig: rig, state: state)
        }

        /// Album "X": a, b, c. Album "Y": tiny, tiny2 (very short).
        private func standard() async throws -> Env {
            try await makeEnv([
                entry(.a, title: "A1", album: "X", track: 1, year: "2001"),
                entry(.b, title: "A2", album: "X", track: 2, year: "2001"),
                entry(.c, title: "A3", album: "X", track: 3, year: "2001"),
                entry(.tiny, title: "B1", album: "Y", track: 1),
                entry(.tiny2, title: "B2", album: "Y", track: 2),
            ])
        }

        // MARK: Starting

        @Test("starting a track shows it and plays it exactly")
        func start() async throws {
            let env = try await standard()
            #expect(env.state.status == .stopped && env.state.isStopped)
            env.state.play(albumIndex: 0, trackIndex: 1)

            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "A2")
            #expect(env.state.info?.artist == "Artist X")
            #expect(env.state.info?.album == "X")
            #expect(env.state.info?.year == "2001")
            #expect(env.state.info?.codec == "FLAC")
            #expect(env.state.position == 0)
            #expect(env.store.playingName == "main")

            try await env.run(6 * Self.slice)
            #expect(env.rig.deviation(of: .b, from: 0, at: 0, count: 6 * Self.slice) == 0)
            #expect(env.state.duration == RampFile.b.duration)           // the exact one, from the file
            #expect(abs(env.state.position - Double(6 * Self.slice) / 44100) < 1e-6)
        }

        @Test("starting from a row: a header starts the album, a track row that track, nonsense nothing")
        func startFromRow() async throws {
            let env = try await standard()
            let rows = env.store.activePlaylist.rows
            #expect(rows[0].isHeader)

            env.state.play(row: 0)
            #expect(env.state.info?.title == "A1")
            env.state.play(row: 2)                       // header, A1, A2
            #expect(env.state.info?.title == "A2")
            let headerOfY = env.store.activePlaylist.headerRow[1]
            env.state.play(row: headerOfY)
            #expect(env.state.info?.title == "B1")

            let before = env.state.info?.title
            env.state.play(row: 999)
            env.state.play(row: -1)
            env.state.play(albumIndex: 5, trackIndex: 0)
            env.state.play(albumIndex: 0, trackIndex: 9)
            #expect(env.state.info?.title == before)
        }

        @Test("starting another track while one plays replaces it")
        func replace() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)
            let at = env.rig.frame
            env.state.play(albumIndex: 0, trackIndex: 2)
            try await env.run(8 * Self.slice)
            #expect(env.state.info?.title == "A3")
            let settled = at + env.rig.fadeFrames + env.rig.fadeInFrames
            #expect(env.rig.deviation(of: .c, from: env.rig.fadeInFrames, at: settled, count: env.rig.frame - settled) == 0)
        }

        // MARK: Following the playlist

        @Test("the tracks of an album follow each other gaplessly, and the display follows along")
        func albumOrder() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            let a = RampFile.a, b = RampFile.b, c = RampFile.c

            try await env.run(a.frames - 1000)
            #expect(env.state.info?.title == "A1")
            try await env.run(2000)
            #expect(env.state.info?.title == "A2")
            #expect(abs(env.state.position - 1000.0 / 44100) < 0.03)    // 1000 frames into the second track

            try await env.run(b.frames - 1000 + 2000)
            #expect(env.state.info?.title == "A3")

            try await env.run(c.frames + 1000)
            // Into the next album: the short tracks of "Y".
            #expect(env.state.info?.album == "Y")

            #expect(env.rig.deviation(of: a, from: 0, at: 0, count: a.frames) == 0)
            #expect(env.rig.deviation(of: b, from: 0, at: a.frames, count: b.frames) == 0)
            #expect(env.rig.deviation(of: c, from: 0, at: a.frames + b.frames, count: c.frames) == 0)
            #expect(env.rig.deviation(of: .tiny, from: 0, at: a.frames + b.frames + c.frames, count: RampFile.tiny.frames) == 0)
        }

        // MARK: Listener

        /// Renders `seconds` of playback in 0.1 s steps, refreshing the state after each, the way the tick does.
        private func listen(_ env: Env, seconds: Double) async throws {
            for _ in 0..<Int((seconds * 10).rounded()) { try await env.run(4410) }
        }

        @Test("the listener hears every track that starts and ends, with the time listened to")
        func listenerFollowsTracks() async throws {
            let listener = RecordingListener()
            let env = try await makeEnv([
                entry(.a, title: "A1", album: "X", track: 1),
                entry(.b, title: "A2", album: "X", track: 2),
            ], listener: listener)
            let before = Date()
            env.state.play(albumIndex: 0, trackIndex: 0)

            #expect(listener.events == [.started("A1")])
            let first = try #require(listener.started.first)
            #expect(first.artist == "Artist X" && first.album == "X")
            #expect(abs(first.startedAt.timeIntervalSince(before)) < 5)

            try await listen(env, seconds: RampFile.a.duration + 0.5)      // into the second track, gaplessly
            #expect(listener.events == [.started("A1"), .ended("A1"), .started("A2")])
            let ended = try #require(listener.ended.first)
            #expect(abs(ended.played - RampFile.a.duration) < 0.3)
            #expect(abs(ended.track.duration - RampFile.a.duration) < 0.01)
            #expect(ended.track.startedAt == first.startedAt)

            env.state.stop()
            #expect(listener.events.suffix(1) == [.ended("A2")])
            #expect(listener.ended.last.map { $0.played > 0.3 && $0.played < 0.7 } == true)
        }

        @Test("picking another track ends the current one; stopping twice reports nothing more")
        func listenerUserChanges() async throws {
            let listener = RecordingListener()
            let env = try await makeEnv([
                entry(.a, title: "A1", album: "X", track: 1),
                entry(.b, title: "A2", album: "X", track: 2),
            ], listener: listener)
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await listen(env, seconds: 1)
            env.state.nextTrack()
            #expect(listener.events == [.started("A1"), .ended("A1"), .started("A2")])
            #expect(abs(listener.ended[0].played - 1) < 0.15)

            env.state.stop()
            env.state.stop()
            #expect(listener.events == [.started("A1"), .ended("A1"), .started("A2"), .ended("A2")])
        }

        @Test("seeking forward isn't listening")
        func listenerIgnoresSeeking() async throws {
            let listener = RecordingListener()
            let env = try await makeEnv([entry(.a, title: "A1", album: "X", track: 1)], listener: listener)
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await listen(env, seconds: 0.5)
            env.state.seek(to: 2.9)
            try await listen(env, seconds: 0.2)
            env.state.stop()

            let played = try #require(listener.ended.first).played
            #expect(played > 0.5 && played < 1.2, "played \(played)")
        }

        // MARK: Cursor

        @Test("the playing row follows the track, and is nil while stopped")
        func playingRow() async throws {
            let env = try await standard()
            #expect(env.state.playingRow == nil)

            env.state.play(albumIndex: 0, trackIndex: 1)
            #expect(env.state.playingRow == 2)                          // header, A1, A2

            try await env.run(RampFile.b.frames + 2000)
            #expect(env.state.info?.title == "A3")
            #expect(env.state.playingRow == 3)

            env.state.play(albumIndex: 1, trackIndex: 1)
            #expect(env.state.playingRow == 6)

            env.state.stop()
            #expect(env.state.playingRow == nil)
        }

        @Test("the playing row is nil while another playlist is shown")
        func playingRowOtherPlaylist() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            #expect(env.state.playingRow == 1)

            try env.store.create(named: "other")
            #expect(env.state.status == .playing)
            #expect(env.state.playingRow == nil)

            env.store.setActive("main")
            #expect(env.state.playingRow == 1)
        }

        @Test("with playback following the cursor, the track under the cursor plays next")
        func playbackFollowsCursor() async throws {
            let env = try await standard()
            #expect(env.state.playbackFollowsCursor)
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.cursorRow = 3                                     // A3, skipping A2

            try await env.run(RampFile.a.frames + 2000)
            #expect(env.state.info?.title == "A3")
        }

        @Test("a cursor on an album header means the first track of that album")
        func cursorOnHeader() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.cursorRow = env.store.activePlaylist.headerRow[1]

            try await env.run(RampFile.a.frames + 2000)
            #expect(env.state.info?.title == "B1")
        }

        @Test("moving the cursor after the next track was prepared replaces it")
        func cursorMovesLate() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(2 * Self.slice)                           // A2 is queued by now
            env.state.cursorRow = 5                                     // B1
            env.state.cursorRow = 3                                     // and then A3

            try await env.run(RampFile.a.frames)
            #expect(env.state.info?.title == "A3")
        }

        @Test("the cursor is followed once: after the selected track, playback continues in playlist order")
        func cursorFollowedOnce() async throws {
            let env = try await standard()
            env.state.cursorFollowsPlayback = false
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.cursorRow = 3                                     // A3, skipping A2

            try await env.run(RampFile.a.frames + 2000)
            #expect(env.state.info?.title == "A3")
            // The cursor still sits on A3, but nobody moved it: on to the next album, not back to A3.
            try await env.run(RampFile.c.frames - 1000)
            #expect(env.state.info?.title == "B1")
        }

        @Test("moving the cursor again makes a new request")
        func cursorMovedAgain() async throws {
            let env = try await standard()
            env.state.cursorFollowsPlayback = false
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.cursorRow = 3
            try await env.run(RampFile.a.frames + 2000)
            #expect(env.state.info?.title == "A3")

            env.state.cursorRow = 1                                     // A1 again
            try await env.run(RampFile.c.frames)
            #expect(env.state.info?.title == "A1")
        }

        @Test("moving the cursor back onto the playing track cancels the request")
        func cursorBackOnPlaying() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.cursorRow = 3
            env.state.cursorRow = 1

            try await env.run(RampFile.a.frames + 2000)
            #expect(env.state.info?.title == "A2")
        }

        @Test("starting a track explicitly drops a pending request")
        func playDropsRequest() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.cursorRow = 5                                     // B1
            env.state.play(albumIndex: 0, trackIndex: 1)                // A2, the cursor stays on B1

            try await env.run(RampFile.b.frames + 2000)
            #expect(env.state.info?.title == "A3")                      // by the playlist order, not the request
        }

        @Test("a cursor on the playing track changes nothing")
        func cursorOnPlaying() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.cursorRow = 1

            try await env.run(RampFile.a.frames + 2000)
            #expect(env.state.info?.title == "A2")
        }

        @Test("with playback not following the cursor, the playlist order rules")
        func playbackDoesNotFollowCursor() async throws {
            let env = try await standard()
            env.state.playbackFollowsCursor = false
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.cursorRow = 3

            try await env.run(RampFile.a.frames + 2000)
            #expect(env.state.info?.title == "A2")

            // Switching it on takes effect for what is selected after that: back to the first track.
            env.state.playbackFollowsCursor = true
            env.state.cursorRow = 1
            try await env.run(RampFile.b.frames)
            #expect(env.state.info?.title == "A1")
        }

        @Test("next track goes to the cursor too")
        func nextTrackFollowsCursor() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.cursorRow = 6
            env.state.nextTrack()
            #expect(env.state.info?.title == "B2")
        }

        /// "main" plays (standard), "other" is shown and has one track, `C1`: row 0 is its header, row 1 the track.
        private func playingWithOtherShown() async throws -> Env {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(2 * Self.slice)
            try env.store.create(named: "other")
            #expect(await waitUntil { !env.store.isLoading })
            await env.store.append(Make.albums([try entry(.c, title: "C1", album: "Z", track: 1)]), to: "other")
            return env
        }

        @Test("the cursor in another playlist than the playing one is followed: the track plays next, from that playlist")
        func cursorOtherPlaylist() async throws {
            let env = try await playingWithOtherShown()
            env.state.cursorRow = 1
            try await env.run(RampFile.a.frames)
            #expect(env.state.info?.title == "C1")
            #expect(env.store.playingName == "other")
            #expect(env.state.playingRow == 1)
            let from = env.rig.frame - 2000
            #expect(env.rig.deviation(of: .c, from: 0, at: RampFile.a.frames, count: 2000) == 0)   // gapless
            #expect(from > 0)

            // The request is served: the playlist it came from is let go, and nothing is queued behind the last track.
            #expect(env.store.playingPlaylist === env.store.activePlaylist)
            env.store.setActive("main")
            #expect(env.state.playingRow == nil)
        }

        @Test("next track goes to the cursor in another playlist at once")
        func nextTrackOtherPlaylist() async throws {
            let env = try await playingWithOtherShown()
            env.state.cursorRow = 1
            let at = env.rig.frame
            env.state.nextTrack()
            #expect(env.state.info?.title == "C1")
            #expect(env.store.playingName == "other")
            try await env.run(8 * Self.slice)
            let settled = at + env.rig.fadeFrames + env.rig.fadeInFrames
            #expect(env.rig.deviation(of: .c, from: env.rig.fadeInFrames, at: settled, count: env.rig.frame - settled) == 0)
        }

        @Test("going back to the playing playlist cancels the request")
        func cursorOtherPlaylistCancelled() async throws {
            let env = try await playingWithOtherShown()
            env.state.cursorRow = 1
            env.store.setActive("main")
            env.state.cursorRow = nil                        // what the playlist view does on a switch
            env.state.cursorRow = env.state.playingRow
            try await env.run(2 * Self.slice)
            try await env.run(RampFile.a.frames)
            #expect(env.state.info?.title == "A2")
            #expect(env.store.playingName == "main")
        }

        @Test("a cursor in another playlist is ignored when playback doesn't follow the cursor")
        func cursorOtherPlaylistOff() async throws {
            let env = try await playingWithOtherShown()
            env.state.playbackFollowsCursor = false
            env.state.cursorRow = 1
            env.state.nextTrack()
            #expect(env.state.info?.title == "A2")
            #expect(env.store.playingName == "main")
        }

        @Test("a request for a track in another playlist that can't be played falls back to the playing playlist")
        func cursorOtherPlaylistFails() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(2 * Self.slice)
            try env.store.create(named: "other")
            #expect(await waitUntil { !env.store.isLoading })
            await env.store.append(Make.albums([Make.entry(env.dir.path("missing.flac").path, album: "Z", title: "Gone", track: 1)]),
                                   to: "other")
            env.state.cursorRow = 1
            try await env.run(2 * Self.slice)                // the engine finds out that the queued file is missing
            try await env.run(RampFile.a.frames)
            #expect(env.state.info?.title == "A2")
            #expect(env.store.playingName == "main")
        }

        @Test("the two options are read from the config and written back when changed")
        func followOptionsPersist() async throws {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            config.update { $0.playback.playbackFollowsCursor = false }
            let store = PlaylistStore(paths: paths, configStore: config)
            let rig = EngineRig(lookahead: 60)
            let state = PlaybackState(store: store, engine: rig.engine, tickInterval: nil, configStore: config)
            #expect(state.cursorFollowsPlayback)
            #expect(!state.playbackFollowsCursor)

            state.cursorFollowsPlayback = false
            state.playbackFollowsCursor = true
            #expect(!config.config.playback.cursorFollowsPlayback)
            #expect(config.config.playback.playbackFollowsCursor)
        }

        @Test("the resample quality is read from the config, handed to the engine and written back when changed")
        func resampleQualityPersists() async throws {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            let store = PlaylistStore(paths: paths, configStore: config)

            let plain = PlaybackState(store: store, engine: EngineRig(lookahead: 60).engine, tickInterval: nil)
            #expect(plain.resampleQuality == .high)

            config.update { $0.playback.resampleQuality = .max }
            let rig = EngineRig(lookahead: 60)
            let state = PlaybackState(store: store, engine: rig.engine, tickInterval: nil, configStore: config)
            #expect(state.resampleQuality == .max)
            #expect(rig.engine.resampleQuality == .max)

            state.resampleQuality = .low
            #expect(rig.engine.resampleQuality == .low)
            #expect(config.config.playback.resampleQuality == .low)
        }

        @Test("the volume is read from the config, handed to the engine and written back when changed")
        func volumePersists() async throws {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            let store = PlaylistStore(paths: paths, configStore: config)
            #expect(PlaybackState(store: store, engine: EngineRig(lookahead: 60).engine, tickInterval: nil).volume == 0.7)

            config.update { $0.playback.volume = 0.25 }
            let rig = EngineRig(lookahead: 60)
            let state = PlaybackState(store: store, engine: rig.engine, tickInterval: nil, configStore: config)
            #expect(state.volume == 0.25)
            #expect(rig.engine.volume == 0.25)

            state.volume = 0.9
            #expect(rig.engine.volume == 0.9)
            #expect(config.config.playback.volume == 0.9)
        }

        @Test("the playlist ends after its last track: stopped, nothing shown, nothing held")
        func endOfPlaylist() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 1, trackIndex: 0)
            try await env.run(RampFile.tiny.frames + RampFile.tiny2.frames + 3 * Self.slice)

            #expect(env.state.status == .stopped)
            #expect(env.state.info == nil)
            #expect(env.state.position == 0 && env.state.duration == 0)
            #expect(env.store.playingName == nil)
            #expect(!env.engine.isActive)
            #expect(env.rig.events.last == "finished")
        }

        @Test("a one-track playlist plays and stops")
        func singleTrack() async throws {
            let env = try await makeEnv([entry(.tiny, title: "Only", album: "Solo", track: 1)])
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)
            #expect(env.state.status == .stopped)
            #expect(env.rig.deviation(of: .tiny, from: 0, at: 0, count: RampFile.tiny.frames) == 0)
        }

        @Test("a long run of very short tracks plays through, each one after the other, without a hole")
        func shortRun() async throws {
            let entries = try (0..<12).map { n in
                try entry(n.isMultiple(of: 2) ? .tiny : .tiny2, title: "S\(n)", album: "Shorts", track: n + 1)
            }
            let env = try await makeEnv(entries)
            env.state.play(albumIndex: 0, trackIndex: 0)
            let files = (0..<12).map { $0.isMultiple(of: 2) ? RampFile.tiny : .tiny2 }
            try await env.run(files.reduce(0) { $0 + $1.frames } + 4 * Self.slice)

            var at = 0
            for (n, file) in files.enumerated() {
                #expect(env.rig.deviation(of: file, from: 0, at: at, count: file.frames) == 0, "track \(n)")
                at += file.frames
            }
            #expect(env.state.status == .stopped)
        }

        @Test("playback goes on from the playing playlist while another one is shown")
        func otherPlaylistShown() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)

            try env.store.create(named: "other")          // becomes the active one
            #expect(env.store.activeName == "other")
            #expect(env.state.status == .playing)
            try await env.run(RampFile.a.frames)          // across the first boundary
            #expect(env.state.info?.title == "A2")
            #expect(env.rig.deviation(of: .b, from: 0, at: RampFile.a.frames, count: 3 * Self.slice) == 0)
        }

        // MARK: Next / previous

        @Test("next track plays the following one, previous the one before; the tracks after follow")
        func nextPrevious() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 1)
            try await env.run(4 * Self.slice)

            env.state.nextTrack()
            #expect(env.state.info?.title == "A3")
            try await env.run(4 * Self.slice)
            env.state.previousTrack()
            #expect(env.state.info?.title == "A2")
            env.state.previousTrack()
            #expect(env.state.info?.title == "A1")
            try await env.run(8 * Self.slice)
            let at = env.rig.frame - 8 * Self.slice
            #expect(env.rig.deviation(of: .a, from: env.rig.fadeInFrames, at: at + env.rig.fadeFrames + env.rig.fadeInFrames,
                                      count: 8 * Self.slice - env.rig.fadeFrames - env.rig.fadeInFrames) == 0)
        }

        @Test("next track crosses into the next album, and does nothing after the very last track")
        func nextTrackAcrossAlbums() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 2)
            env.state.nextTrack()
            #expect(env.state.info?.title == "B1")
            #expect(env.state.info?.album == "Y")
            env.state.nextTrack()
            #expect(env.state.info?.title == "B2")
            try await env.run(4 * Self.slice)
            #expect(env.state.status == .playing || env.state.status == .stopped)

            env.state.play(albumIndex: 1, trackIndex: 1)
            env.state.nextTrack()                         // last track: nothing
            #expect(env.state.info?.title == "B2")
            #expect(env.state.status == .playing)
        }

        @Test("previous track goes back across albums, and restarts the very first track")
        func previousTrackAcrossAlbums() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 1, trackIndex: 0)
            env.state.previousTrack()
            #expect(env.state.info?.title == "A3")
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(8 * Self.slice)
            #expect(env.state.position > 0.1)
            env.state.previousTrack()                     // first track of the first album: from the beginning
            #expect(env.state.info?.title == "A1")
            #expect(env.state.position == 0)
            try await env.run(8 * Self.slice)
            #expect(env.state.position < 0.3)
        }

        @Test("next and previous album start the first track of that album")
        func albums() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 2)
            env.state.nextAlbum()
            #expect(env.state.info?.title == "B1")
            env.state.nextAlbum()                         // last album: nothing
            #expect(env.state.info?.title == "B1")
            env.state.play(albumIndex: 1, trackIndex: 1)
            env.state.previousAlbum()
            #expect(env.state.info?.title == "A1")
            env.state.play(albumIndex: 0, trackIndex: 2)
            env.state.previousAlbum()                     // first album: its first track again
            #expect(env.state.info?.title == "A1")
        }

        // MARK: Random, play/pause, volume (the hotkeys' commands)

        @Test("random track plays any other track of the playing playlist, never the current one")
        func randomTrack() async throws {
            let env = try await standard()
            let titles = ["A1", "A2", "A3", "B1", "B2"]
            for (current, title) in titles.enumerated() {
                var picked: Set<String> = []
                for choice in 0..<4 {
                    env.state.play(albumIndex: current < 3 ? 0 : 1, trackIndex: current < 3 ? current : current - 3)
                    env.state.randomIndex = { count in
                        #expect(count == 4)           // the current track is not among the candidates
                        return choice
                    }
                    env.state.randomTrack()
                    let new = try #require(env.state.info?.title)
                    #expect(new != title)
                    picked.insert(new)
                }
                #expect(picked == Set(titles).subtracting([title]))   // every other track is reachable
            }
        }

        @Test("random album plays the first track of another album")
        func randomAlbum() async throws {
            let env = try await standard()
            env.state.randomIndex = { count in
                #expect(count == 1)
                return 0
            }
            env.state.play(albumIndex: 0, trackIndex: 2)
            env.state.randomAlbum()
            #expect(env.state.info?.title == "B1")
            env.state.randomAlbum()
            #expect(env.state.info?.title == "A1")
        }

        @Test("random with nothing else to pick plays the only track")
        func randomSingle() async throws {
            let env = try await makeEnv([entry(.a, title: "Only", album: "X", track: 1)])
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.randomTrack()
            #expect(env.state.info?.title == "Only")
            #expect(env.state.status == .playing)
            env.state.randomAlbum()
            #expect(env.state.info?.title == "Only")
        }

        @Test("random while stopped starts a track of the active playlist")
        func randomWhileStopped() async throws {
            let env = try await standard()
            env.state.randomIndex = { _ in 3 }
            env.state.randomTrack()
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "B1")

            env.state.stop()
            env.state.randomIndex = { _ in 1 }
            env.state.randomAlbum()
            #expect(env.state.info?.title == "B1")
        }

        @Test("play/pause starts the track under the cursor while stopped, otherwise pauses and resumes")
        func playPause() async throws {
            let env = try await standard()
            env.state.playPause()                         // no cursor: nothing to start
            #expect(env.state.status == .stopped)

            env.state.cursorRow = 3                       // header X, A1, A2, A3 -> row 3 is A3
            env.state.playPause()
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "A3")
            env.state.playPause()
            #expect(env.state.status == .paused)
            env.state.playPause()
            #expect(env.state.status == .playing)
        }

        @Test("resume and pause only do their own thing")
        func resumeAndPause() async throws {
            let env = try await standard()
            env.state.pause()
            #expect(env.state.status == .stopped)
            env.state.resume()                            // stopped, no cursor
            #expect(env.state.status == .stopped)

            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.resume()
            #expect(env.state.status == .playing)
            env.state.pause()
            #expect(env.state.status == .paused)
            env.state.pause()
            #expect(env.state.status == .paused)
            env.state.resume()
            #expect(env.state.status == .playing)

            env.state.stop()
            env.state.cursorRow = 1
            env.state.resume()                            // stopped: starts what is under the cursor
            #expect(env.state.info?.title == "A1")
        }

        @Test("volume steps by 5% and stays within 0...1")
        func volumeSteps() async throws {
            let env = try await standard()
            env.state.volume = 0.7
            env.state.volumeUp()
            #expect(env.state.volume == 0.75)
            env.state.volumeDown()
            env.state.volumeDown()
            #expect(env.state.volume == 0.65)

            env.state.volume = 0.97
            env.state.volumeUp()
            #expect(env.state.volume == 1)
            env.state.volumeUp()
            #expect(env.state.volume == 1)

            env.state.volume = 0.02
            env.state.volumeDown()
            #expect(env.state.volume == 0)
            env.state.volumeDown()
            #expect(env.state.volume == 0)

            env.state.volume = 0
            for _ in 0..<20 { env.state.volumeUp() }
            #expect(env.state.volume == 1)                // no drift from repeated steps
        }

        @Test("navigation commands do nothing while stopped")
        func navigationWhileStopped() async throws {
            let env = try await standard()
            env.state.nextTrack()
            env.state.previousTrack()
            env.state.nextAlbum()
            env.state.previousAlbum()
            env.state.togglePause()
            env.state.seek(to: 3)
            env.state.tick()
            #expect(env.state.status == .stopped && env.state.info == nil)
            #expect(!env.engine.isActive)
        }

        @Test("next track while the engine has just crossed a boundary: the display and the audio agree")
        func nextAtBoundary() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.rig.render(RampFile.a.frames + 10)   // crossed, but no tick() yet
            env.state.nextTrack()                              // must skip the track that already follows
            #expect(env.state.info?.title == "A3")
        }

        // MARK: Pause, seek, stop

        @Test("pause and play again")
        func togglePause() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(6 * Self.slice)

            env.state.togglePause()
            #expect(env.state.status == .paused)
            try await env.run(6 * Self.slice)
            let frozen = env.state.position
            try await env.run(4 * Self.slice)
            #expect(env.state.position == frozen)
            #expect(env.state.info?.title == "A1")         // still shown while paused

            env.state.togglePause()
            #expect(env.state.status == .playing)
            try await env.run(6 * Self.slice)
            #expect(env.state.position > frozen)
        }

        @Test("a seek moves the position at once and the audio follows exactly")
        func seek() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)
            let at = env.rig.frame
            env.state.seek(to: 1.5)
            #expect(env.state.position == 1.5)
            try await env.run(8 * Self.slice)

            let first = Int((1.5 * 44100).rounded())
            let settled = at + env.rig.fadeFrames + env.rig.fadeInFrames
            #expect(env.rig.deviation(of: .a, from: first + env.rig.fadeInFrames, at: settled, count: env.rig.frame - settled) == 0)
            #expect(env.state.position > 1.5)
        }

        @Test("a seek is limited to the track: just before its end at most, below zero means the beginning")
        func seekClamped() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(2 * Self.slice)          // the duration is known now
            env.state.seek(to: 10_000)
            #expect(env.state.position <= RampFile.a.duration - 0.04)
            #expect(env.state.position >= RampFile.a.duration - 0.06)
            env.state.seek(to: -4)
            #expect(env.state.position == 0)
        }

        @Test("seeking before the length of the track is known is ignored, as the position can't be limited yet")
        func seekBeforeDuration() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            #expect(env.state.duration == 0)
            env.state.seek(to: 1)
            #expect(env.state.position == 0)
        }

        @Test("seeking a paused track keeps it paused at the new position")
        func seekPaused() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)
            env.state.togglePause()
            try await env.run(4 * Self.slice)
            env.state.seek(to: 2)
            try await env.run(4 * Self.slice)
            #expect(env.state.status == .paused)
            #expect(env.state.position == 2)
            #expect(isSilent(env.rig.out, in: (env.rig.frame - 3 * Self.slice)..<env.rig.frame))
        }

        @Test("stop clears everything and lets go of the playlist")
        func stop() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 1)
            try await env.run(6 * Self.slice)
            env.state.stop()

            #expect(env.state.status == .stopped)
            #expect(env.state.info == nil && env.state.artwork == nil)
            #expect(env.state.position == 0 && env.state.duration == 0)
            #expect(env.store.playingName == nil)
            try await env.run(6 * Self.slice)
            #expect(isSilent(env.rig.out, in: (env.rig.frame - 4 * Self.slice)..<env.rig.frame))
            #expect(!env.engine.isActive)
            #expect(env.rig.events.isEmpty)       // stopping isn't "finished"
        }

        @Test("a stopped player starts again from the next play command")
        func playAfterStop() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)
            env.state.stop()
            try await env.run(4 * Self.slice)
            let at = env.rig.frame
            env.state.play(albumIndex: 0, trackIndex: 1)
            try await env.run(6 * Self.slice)
            #expect(env.state.info?.title == "A2")
            #expect(env.rig.deviation(of: .b, from: env.rig.fadeInFrames, at: at + env.rig.fadeInFrames,
                                      count: 6 * Self.slice - env.rig.fadeInFrames) == 0)
        }

        @Test("deleting the playlist that plays stops the playback")
        func deletePlaying() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)
            try env.store.create(named: "other")
            try await env.store.delete("main")
            #expect(env.state.status == .stopped)
            #expect(env.store.playingName == nil)
        }

        @Test("the volume reaches the output")
        func volume() async throws {
            let env = try await standard()
            env.state.volume = 0.5
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(10 * Self.slice)
            let from = 6 * Self.slice
            let d = maxDeviation(env.rig.out, from: from, count: 4 * Self.slice) { RampFile.a.value(from + $0, channel: $1) * 0.5 }
            #expect(d < 1e-6)
        }

        // MARK: A playlist that grows

        @Test("tracks appended while the last one plays continue the playback gaplessly")
        func appendToLast() async throws {
            let env = try await makeEnv([entry(.a, title: "A1", album: "X", track: 1)])
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)

            await env.store.append(Make.albums([try entry(.b, title: "N1", album: "New", track: 1)]), to: "main")
            try await env.run(RampFile.a.frames + 4 * Self.slice)

            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "N1")
            #expect(env.rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
            #expect(env.rig.deviation(of: .b, from: 0, at: RampFile.a.frames, count: 3 * Self.slice) == 0)
        }

        @Test("tracks appended to the album that plays join it, and play after its current last track")
        func appendToAlbum() async throws {
            let env = try await makeEnv([entry(.tiny, title: "A1", album: "X", track: 1)])
            env.state.play(albumIndex: 0, trackIndex: 0)
            await env.store.append(Make.albums([try entry(.b, title: "A2", album: "X", track: 2)]), to: "main")
            #expect(env.store.activePlaylist.albums.count == 1)
            try await env.run(RampFile.tiny.frames + 4 * Self.slice)
            #expect(env.state.info?.title == "A2")
            #expect(env.rig.deviation(of: .b, from: 0, at: RampFile.tiny.frames, count: 3 * Self.slice) == 0)
        }

        @Test("tracks appended behind the next one change nothing about what is queued")
        func appendFarAway() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)
            await env.store.append(Make.albums([try entry(.c, title: "Z1", album: "Z", track: 1)]), to: "main")
            try await env.run(RampFile.a.frames + RampFile.b.frames)
            // No restart: a and b are exact and contiguous, without any fade between them.
            #expect(env.rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
            #expect(env.rig.deviation(of: .b, from: 0, at: RampFile.a.frames, count: RampFile.b.frames - 4 * Self.slice) == 0)
        }

        @Test("tracks appended once the playback has stopped are just playlist content")
        func appendWhileStopped() async throws {
            let env = try await standard()
            await env.store.append(Make.albums([try entry(.c, title: "Z1", album: "Z", track: 1)]), to: "main")
            #expect(env.state.status == .stopped)
            #expect(!env.engine.isActive)
        }

        // MARK: Tracks that fail

        private func entryMissing(title: String, album: String, track: Int) -> TrackEntry {
            Make.entry("/nonexistent/\(title).flac", artist: "Artist \(album)", album: album, title: title, track: track)
        }

        @Test("a track that can't be opened is skipped when it is next in line")
        func skipMissingNext() async throws {
            let env = try await makeEnv([
                entry(.tiny, title: "A1", album: "X", track: 1),
                entryMissing(title: "Gone", album: "X", track: 2),
                entry(.tiny2, title: "A3", album: "X", track: 3),
            ])
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(RampFile.tiny.frames + RampFile.tiny2.frames + 4 * Self.slice)

            #expect(env.rig.events.contains("failed:Gone.flac:next"))
            #expect(env.rig.deviation(of: .tiny, from: 0, at: 0, count: RampFile.tiny.frames) == 0)
            #expect(env.rig.deviation(of: .tiny2, from: 0, at: RampFile.tiny.frames, count: RampFile.tiny2.frames) == 0)
            #expect(env.state.status == .stopped)
        }

        @Test("a track that can't be opened when started is skipped, the next one plays")
        func skipMissingCurrent() async throws {
            let env = try await makeEnv([
                entryMissing(title: "Gone", album: "X", track: 1),
                entry(.b, title: "A2", album: "X", track: 2),
            ])
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(6 * Self.slice)
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "A2")
            #expect(env.rig.deviation(of: .b, from: 0, at: 0, count: 6 * Self.slice) == 0)
        }

        @Test("several missing tracks in a row are all skipped")
        func skipSeveral() async throws {
            let env = try await makeEnv([
                entry(.tiny, title: "A1", album: "X", track: 1),
                entryMissing(title: "G1", album: "X", track: 2),
                entryMissing(title: "G2", album: "X", track: 3),
                entryMissing(title: "G3", album: "X", track: 4),
                entry(.tiny2, title: "A5", album: "X", track: 5),
            ])
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(RampFile.tiny.frames + RampFile.tiny2.frames + 6 * Self.slice)
            #expect(env.rig.deviation(of: .tiny2, from: 0, at: RampFile.tiny.frames, count: RampFile.tiny2.frames) == 0)
            #expect(env.rig.events.filter { $0.hasPrefix("failed") }.count >= 3)
        }

        @Test("a playlist of nothing but missing tracks stops")
        func allMissing() async throws {
            let env = try await makeEnv([
                entryMissing(title: "G1", album: "X", track: 1),
                entryMissing(title: "G2", album: "X", track: 2),
            ])
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(6 * Self.slice)
            #expect(env.state.status == .stopped)
            #expect(env.store.playingName == nil)
        }

        @Test("a missing last track ends the playback after the one before it")
        func missingLast() async throws {
            let env = try await makeEnv([
                entry(.tiny, title: "A1", album: "X", track: 1),
                entryMissing(title: "Gone", album: "X", track: 2),
            ])
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(RampFile.tiny.frames + 4 * Self.slice)
            #expect(env.state.status == .stopped)
            #expect(env.rig.deviation(of: .tiny, from: 0, at: 0, count: RampFile.tiny.frames) == 0)
        }

        @Test("next track skips over a missing one too")
        func nextOverMissing() async throws {
            let env = try await makeEnv([
                entry(.a, title: "A1", album: "X", track: 1),
                entryMissing(title: "Gone", album: "X", track: 2),
                entry(.c, title: "A3", album: "X", track: 3),
            ])
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)
            env.state.nextTrack()                  // onto the missing one
            try await env.run(8 * Self.slice)
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "A3")
        }

        // MARK: The display

        @Test("the position and duration shown are refreshed by tick")
        func tick() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.rig.render(4 * Self.slice)
            #expect(env.state.position == 0)                  // not refreshed yet
            env.state.tick()
            #expect(abs(env.state.position - Double(4 * Self.slice) / 44100) < 1e-6)
            #expect(env.state.duration == RampFile.a.duration)
        }

        @Test("the position is only published when it moves into another step")
        func positionStep() async throws {
            let env = try await makeEnv([try entry(.a, title: "A1", album: "X", track: 1)], positionStep: 1)
            env.state.play(albumIndex: 0, trackIndex: 0)

            try await env.run(22050)                          // 0.5 s: still in the first second
            #expect(env.state.position == 0)
            try await env.run(44100)                          // 1.5 s: in the next one, published as it is
            #expect(abs(env.state.position - 1.5) < 0.03)
            let published = env.state.position
            try await env.run(13230)                          // 1.8 s: same second, no change
            #expect(env.state.position == published)
            try await env.run(13230)                          // 2.1 s
            #expect(abs(env.state.position - 2.1) < 0.03)
        }

        @Test("the duration of a track comes from the tags until the file says better")
        func durationFromTags() async throws {
            let entries = [Make.entry(try RampFile.a.url().path, artist: "A", album: "X", title: "T", track: 1, duration: 123)]
            let env = try await makeEnv(entries)
            env.state.play(albumIndex: 0, trackIndex: 0)
            #expect(env.state.duration == 123)
            try await env.run(2 * Self.slice)
            #expect(env.state.duration == RampFile.a.duration)
            // And seeking works at once when the tags knew the length.
            env.state.seek(to: 1)
            #expect(env.state.position == 1)
        }

        // MARK: What the file says

        @Test("the real duration and format of the file are written to the playlist, and shown")
        func fileInfoPushed() async throws {
            let entries = [Make.entry(try RampFile.a.url().path, artist: "A", album: "X", title: "T", track: 1, duration: 123)]
            let env = try await makeEnv(entries)
            #expect(env.store.activePlaylist.albums[0].tracks[0].codec == "FLAC")
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(2 * Self.slice)

            let track = env.store.activePlaylist.albums[0].tracks[0]
            #expect(track.duration == RampFile.a.duration)
            #expect(track.codec == "FLAC 16/44.1")
            #expect(env.state.info?.codec == "FLAC 16/44.1")

            await env.store.flushWrites()
            guard case .loaded(let onDisk, _) = PlaylistFile.load(from: env.dir.path("work/playlists/main.json")) else {
                Issue.record("expected a valid file")
                return
            }
            #expect(onDisk.albums[0].tracks[0].duration == RampFile.a.duration)
            #expect(onDisk.albums[0].tracks[0].codec == "FLAC 16/44.1")
        }

        @Test("a duration that is nearly right and the same format leave the playlist alone")
        func fileInfoMatches() async throws {
            let entries = [Make.entry(try RampFile.a.url().path, artist: "A", album: "X", title: "T", track: 1,
                                      duration: RampFile.a.duration + 0.2, codec: "FLAC 16/44.1")]
            let env = try await makeEnv(entries)
            let before = env.store.activePlaylist
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(2 * Self.slice)
            #expect(env.store.activePlaylist === before)
            #expect(env.state.duration == RampFile.a.duration)   // the display uses the exact one regardless
        }

        @Test("a track that is missing its duration gets it")
        func fileInfoMissingDuration() async throws {
            let entries = [Make.entry(try RampFile.a.url().path, artist: "A", album: "X", title: "T", track: 1,
                                      codec: "FLAC 16/44.1")]
            let env = try await makeEnv(entries)
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(2 * Self.slice)
            #expect(env.store.activePlaylist.albums[0].tracks[0].duration == RampFile.a.duration)
        }

        @Test("the tracks that follow are updated as they start")
        func fileInfoNextTrack() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(2 * Self.slice)
            try await env.run(RampFile.a.frames)
            try await env.run(2 * Self.slice)
            #expect(env.state.info?.title == "A2")
            let tracks = env.store.activePlaylist.albums[0].tracks
            #expect(tracks[0].duration == RampFile.a.duration)
            #expect(tracks[1].duration == RampFile.b.duration)
            #expect(tracks[2].duration == nil)                 // not played yet
        }

        // MARK: Changing the playlist under the playback

        @Test("removing tracks before the playing one keeps it playing, at its new row")
        func removeBefore() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 2)       // A3, row 3
            try await env.run(4 * Self.slice)
            let position = env.state.position
            #expect(env.state.playingRow == 3)

            await env.store.remove(ids: [1, 2], from: "main")   // A1, A2
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "A3")
            #expect(env.state.playingRow == 1)
            #expect(env.state.position == position)
            try await env.run(4 * Self.slice)
            #expect(env.rig.deviation(of: .c, from: 4 * Self.slice, at: env.rig.frame - 4 * Self.slice, count: 4 * Self.slice) == 0)
        }

        @Test("removing the playing track stops the playback")
        func removePlaying() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 1)
            try await env.run(2 * Self.slice)
            await env.store.remove(ids: [2], from: "main")
            #expect(env.state.status == .stopped)
            #expect(env.state.info == nil)
            #expect(env.store.playingName == nil)
            #expect(!env.engine.isActive)
        }

        @Test("removing the track that was queued next queues the one after it")
        func removeNext() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(2 * Self.slice)
            await env.store.remove(ids: [2], from: "main")   // A2
            try await env.run(RampFile.a.frames)
            #expect(env.state.info?.title == "A3")
        }

        @Test("the same file twice in the playlist: the one that plays is followed, whichever is removed")
        func removeDuplicates() async throws {
            let first = try entry(.a, title: "First", album: "X", track: 1)
            let env = try await makeEnv([first,
                                         try entry(.b, title: "B", album: "X", track: 2),
                                         try entry(.a, title: "Second", album: "X", track: 3)])
            let ids = env.store.activePlaylist.albums[0].tracks.map(\.id)
            env.state.play(albumIndex: 0, trackIndex: 2)       // the second copy
            try await env.run(2 * Self.slice)
            #expect(env.state.playingRow == 3)

            await env.store.remove(ids: [ids[0]], from: "main")
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "Second")
            #expect(env.state.playingRow == 2)

            await env.store.remove(ids: [ids[1]], from: "main")   // and the one between them
            #expect(env.state.info?.title == "Second")
            #expect(env.state.playingRow == 1)
        }

        @Test("the tracks that start are the playlist's last played one, in the file too")
        func lastPlayed() async throws {
            let env = try await standard()
            #expect(env.store.lastPlayedRow == nil)
            env.state.play(albumIndex: 0, trackIndex: 1)       // A2, row 2
            #expect(env.store.lastPlayedRow == 2)

            try await env.run(RampFile.b.frames + 2 * Self.slice)   // on to A3
            #expect(env.state.info?.title == "A3")
            #expect(env.store.lastPlayedRow == 3)

            env.state.stop()
            #expect(env.store.lastPlayedRow == 3)              // stays after the playback ended
            await env.store.flushWrites()
            let data = try Data(contentsOf: env.dir.path("work/playlists/main.json"))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["last_played"] as? Int == 3)
        }

        @Test("a track that moves to another row is still the last played one")
        func lastPlayedMoves() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 2)       // A3, row 3
            await env.store.remove(ids: [1], from: "main")
            #expect(env.store.lastPlayedRow == 2)
            await env.store.setFlat(true)
            #expect(env.store.lastPlayedRow == 1)
        }

        @Test("placing the cursor in another playlist doesn't make playback go there")
        func placeCursorOtherPlaylist() async throws {
            let env = try await playingWithOtherShown()
            env.state.placeCursor(at: 1)                       // what opening the playlist does
            #expect(env.state.cursorRow == 1)
            try await env.run(RampFile.a.frames)
            #expect(env.state.info?.title == "A2")
            #expect(env.store.playingName == "main")

            env.state.nextTrack()
            #expect(env.state.info?.title == "A3")
        }

        @Test("placing the cursor drops a request made before it")
        func placeCursorDropsRequest() async throws {
            let env = try await playingWithOtherShown()
            env.state.cursorRow = 1                            // a request for C1 in the other playlist
            env.state.placeCursor(at: nil)
            try await env.run(RampFile.a.frames)
            #expect(env.state.info?.title == "A2")
            #expect(env.store.playingName == "main")
        }

        @Test("a cursor that was placed is not a request, but moving it afterwards is")
        func placeCursorThenMove() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.placeCursor(at: 5)                       // B1
            try await env.run(RampFile.a.frames + 2000)
            #expect(env.state.info?.title == "A2")

            env.state.cursorRow = 3                            // A3: the user's choice
            try await env.run(RampFile.b.frames)
            #expect(env.state.info?.title == "A3")
        }

        @Test("the cursor can be placed while stopped, and then starts a track like a click would")
        func placeCursorStopped() async throws {
            let env = try await standard()
            env.state.placeCursor(at: 3)
            #expect(env.state.cursorRow == 3)
            #expect(env.state.status == .stopped)
            env.state.play(row: 3)
            #expect(env.state.info?.title == "A3")
        }

        @Test("switching to a flat playlist keeps the playing track playing, and what follows is the next row")
        func flatWhilePlaying() async throws {
            let env = try await standard()
            env.state.play(albumIndex: 0, trackIndex: 1)       // A2
            try await env.run(2 * Self.slice)
            #expect(env.state.playingRow == 2)

            await env.store.setFlat(true)
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "A2")
            #expect(env.state.playingRow == 1)                 // no headers any more
            #expect(env.store.activePlaylist.rows.count == 5)

            try await env.run(RampFile.b.frames)
            #expect(env.state.info?.title == "A3")
            #expect(env.state.playingRow == 2)

            await env.store.setFlat(false)
            #expect(env.state.info?.title == "A3")
            #expect(env.state.playingRow == 3)
        }

        @Test("reloaded tags that move the playing track into another album are followed")
        func reloadWhilePlaying() async throws {
            let env = try await standard()
            let path = try RampFile.b.url().path
            env.state.play(albumIndex: 0, trackIndex: 1)
            try await env.run(2 * Self.slice)

            await env.store.applyTags([Make.result(path, title: "Renamed", artist: "Artist X", album: "Z")], to: "main")
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "Renamed")
            #expect(env.state.info?.album == "Z")
            #expect(env.store.activePlaylist.albums.map(\.title) == ["X", "Z", "Y"])
            #expect(env.state.playingRow == 4)                 // X header, 2 tracks, Z header, Renamed
        }
    }
}
