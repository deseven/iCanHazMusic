// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// Where playback stands is kept in the config while something plays, and picked up again at the next launch
    /// ("Restore Playback State"). A launch here is a `ConfigStore`, `PlaylistStore` and `PlaybackState` on the same
    /// working directory, on an offline engine.
    @MainActor @Suite("PlaybackState: restoring")
    struct PlaybackRestoreTests {
        private static let slice = PlaybackEngine.renderSlice

        private typealias Saved = AppConfig.Playback.SavedState

        @MainActor private struct Launch {
            let dir: TempDir
            let paths: AppPaths
            let config: ConfigStore
            let store: PlaylistStore
            let rig: EngineRig
            let state: PlaybackState

            var saved: Saved? { config.config.playback.state }

            /// Renders `frames` and refreshes what the now playing block would show.
            func run(_ frames: Int) async throws {
                try await rig.render(frames)
                state.tick()
            }

            /// Renders `seconds` of playback in 0.1 s steps, refreshing the state after each, the way the tick does.
            func listen(_ seconds: Double) async throws {
                for _ in 0..<Int((seconds * 10).rounded()) { try await run(4410) }
            }

            /// What `AppDelegate` does when the app quits.
            func quit() async {
                await state.stopAndWait()
                await store.flushWrites()
                config.flush()
            }

            /// The ID of a track of the playlist (by album and place in it).
            func id(of playlist: String = "main", album: Int = 0, track: Int) throws -> TrackID {
                try #require(store.playlist(named: playlist)).albums[album].tracks[track].id
            }
        }

        private func entry(_ file: RampFile, title: String, album: String = "X", track: Int) throws -> TrackEntry {
            Make.entry(try file.url().path, artist: "Artist \(album)", album: album, title: title, track: track)
        }

        /// Album "X": A1 (3.1 s), A2 (2.5 s), A3 (2 s).
        private func standard() throws -> [TrackEntry] {
            [try entry(.a, title: "A1", track: 1), try entry(.b, title: "A2", track: 2), try entry(.c, title: "A3", track: 3)]
        }

        /// One launch of the app on `dir`: with `entries` they are added to the playlist "main" first (a first launch).
        /// `waitForPlaylists` off: the playlists are still being read when this returns.
        private func launch(in dir: TempDir, entries: [TrackEntry] = [], listener: PlaybackListener? = nil,
                            waitForPlaylists: Bool = true) async throws -> Launch {
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            let store = PlaylistStore(paths: paths, configStore: config)
            if waitForPlaylists { #expect(await waitUntil { !store.isLoading }) }
            if !entries.isEmpty { await store.append(Make.albums(entries), to: "main") }
            let rig = EngineRig()
            let state = PlaybackState(store: store, engine: rig.engine, tickInterval: nil, positionStep: 0,
                                      configStore: config, listeners: listener.map { [$0] } ?? [])
            state.volume = 1
            // The state is the engine's listener now; keep recording what the engine reports.
            let stateListener = rig.engine.onEvent
            rig.engine.onEvent = { [weak rig] event in
                rig?.record(event)
                stateListener?(event)
            }
            return Launch(dir: dir, paths: paths, config: config, store: store, rig: rig, state: state)
        }

        /// A directory with a playlist "main" of `entries`, and `state` as what the last run left in the config.
        private func leftBehind(_ state: (Launch) throws -> Saved, entries: [TrackEntry]? = nil) async throws -> TempDir {
            let dir = try TempDir()
            let first = try await launch(in: dir, entries: try entries ?? standard())
            let saved = try state(first)
            first.config.update { $0.playback.state = saved }
            await first.quit()
            return dir
        }

        // MARK: Keeping it

        @Test("a track that starts is kept at its start, then its position every few seconds")
        func keepsWhilePlaying() async throws {
            let env = try await launch(in: try TempDir(), entries: standard())
            let a2 = try env.id(track: 1)
            #expect(env.saved == nil)
            env.state.stateSaveInterval = 1

            env.state.play(albumIndex: 0, trackIndex: 1)
            #expect(env.saved == Saved(playlist: "main", trackID: a2, position: 0, paused: false))

            try await env.listen(0.5)
            #expect(env.saved?.position == 0)                      // not yet
            try await env.listen(0.7)
            let position = try #require(env.saved).position
            #expect(position > 0.9 && position < 1.3, "saved \(position)")
            #expect(env.saved?.trackID == a2)
        }

        @Test("pausing, resuming and seeking are kept, and stopping forgets it")
        func followsPlayback() async throws {
            let env = try await launch(in: try TempDir(), entries: standard())
            let a1 = try env.id(track: 0)
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.listen(1)

            env.state.pause()
            let paused = try #require(env.saved)
            #expect(paused.paused && paused.trackID == a1 && abs(paused.position - 1) < 0.2)

            env.state.resume()
            #expect(env.saved?.paused == false)

            env.state.seek(to: 2)
            #expect(env.saved?.position == 2)

            env.state.stop()
            #expect(env.saved == nil)
        }

        @Test("moving on to the next track by itself is kept")
        func keepsNextTrack() async throws {
            let env = try await launch(in: try TempDir(), entries: standard())
            let a2 = try env.id(track: 1)
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.listen(RampFile.a.duration + 0.5)
            #expect(env.state.info?.title == "A2")
            #expect(env.saved?.trackID == a2)
        }

        @Test("the end of the playlist forgets it, and so does a track that is removed")
        func forgetsWhenOver() async throws {
            let env = try await launch(in: try TempDir(), entries: [try entry(.tiny, title: "Only", track: 1)])
            env.state.play(albumIndex: 0, trackIndex: 0)
            #expect(env.saved != nil)
            try await env.run(4 * Self.slice)
            #expect(env.state.status == .stopped)
            #expect(env.saved == nil)

            let other = try await launch(in: try TempDir(), entries: standard())
            other.state.play(albumIndex: 0, trackIndex: 1)
            #expect(other.saved != nil)
            await other.store.remove(ids: [try other.id(track: 1)], from: "main")
            #expect(other.state.status == .stopped)
            #expect(other.saved == nil)
        }

        @Test("turning the setting off forgets what was kept, turning it on keeps it again")
        func toggling() async throws {
            let env = try await launch(in: try TempDir(), entries: standard())
            let a1 = try env.id(track: 0)
            #expect(env.state.restoresState)
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.listen(0.3)
            #expect(env.saved != nil)

            env.state.restoresState = false
            #expect(env.saved == nil)
            #expect(!env.config.config.general.restorePlaybackState)
            env.state.seek(to: 1)
            env.state.pause()
            #expect(env.saved == nil)

            env.state.restoresState = true
            #expect(env.config.config.general.restorePlaybackState)
            let saved = try #require(env.saved)
            #expect(saved.trackID == a1 && saved.paused && saved.position == 1)
        }

        // MARK: Quitting

        @Test("quitting keeps what plays for the next launch, and the listeners aren't told the track ended")
        func quitKeeps() async throws {
            let listener = RecordingListener()
            let env = try await launch(in: try TempDir(), entries: standard(), listener: listener)
            let a2 = try env.id(track: 1)
            env.state.play(albumIndex: 0, trackIndex: 1)
            try await env.listen(1)
            await env.quit()

            #expect(env.state.status == .stopped)
            #expect(listener.events == [.started("A2")])              // put aside, not left
            let saved = try #require(env.saved)
            #expect(saved.trackID == a2 && !saved.paused && abs(saved.position - 1) < 0.2)
            let reloaded = ConfigStore(paths: env.paths, saveDelay: .seconds(60))
            #expect(reloaded.config.playback.state == saved)
        }

        @Test("quitting while paused keeps it paused; quitting while stopped keeps nothing")
        func quitPausedOrStopped() async throws {
            let env = try await launch(in: try TempDir(), entries: standard())
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.listen(0.5)
            env.state.pause()
            await env.quit()
            #expect(env.saved?.paused == true)

            let stopped = try await launch(in: try TempDir(), entries: standard())
            stopped.state.play(albumIndex: 0, trackIndex: 0)
            stopped.state.stop()
            await stopped.quit()
            #expect(stopped.saved == nil)
            #expect(ConfigStore(paths: stopped.paths, saveDelay: .seconds(60)).config.playback.state == nil)
        }

        @Test("with the setting off quitting ends the track for the listeners, and nothing is kept")
        func quitSettingOff() async throws {
            let listener = RecordingListener()
            let env = try await launch(in: try TempDir(), entries: standard(), listener: listener)
            env.state.restoresState = false
            env.state.play(albumIndex: 0, trackIndex: 1)
            try await env.listen(1)
            await env.quit()
            #expect(listener.events == [.started("A2"), .ended("A2")])
            #expect(env.saved == nil)
        }

        // MARK: Picking it up

        @Test("a launch goes on with the track from the saved position, playing")
        func restorePlaying() async throws {
            let dir = try await leftBehind { Saved(playlist: "main", trackID: try $0.id(track: 1), position: 1, paused: false) }
            let env = try await launch(in: dir)
            let a2 = try env.id(track: 1)
            #expect(env.saved?.position == 1)
            #expect(env.state.status == .stopped)

            await env.state.restorePlayback()
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "A2")
            #expect(env.store.playingName == "main")
            #expect(env.state.position == 1)

            try await env.run(6 * Self.slice)
            #expect(env.rig.deviation(of: .b, from: 44100, at: 0, count: 6 * Self.slice) == 0)
            #expect(abs(env.state.position - (1 + Double(6 * Self.slice) / 44100)) < 0.01)
            #expect(env.saved?.trackID == a2 && env.saved?.paused == false)
        }

        @Test("a paused track comes back paused, silent, and plays on from there when resumed")
        func restorePaused() async throws {
            let listener = RecordingListener()
            let dir = try await leftBehind { Saved(playlist: "main", trackID: try $0.id(track: 1), position: 1, paused: true) }
            let env = try await launch(in: dir, listener: listener)

            await env.state.restorePlayback()
            #expect(env.state.status == .paused)
            #expect(env.state.info?.title == "A2")
            #expect(env.state.position == 1)
            #expect(env.saved?.paused == true)

            try await env.run(3 * Self.slice)
            #expect(env.rig.firstSound() == nil)
            #expect(env.state.position == 1)
            #expect(env.state.duration == RampFile.b.duration)           // the file has been opened
            #expect(listener.events == [.started("A2")])                 // what lyrics and the waveform follow

            env.state.resume()
            try await env.run(3 * Self.slice)
            #expect(env.state.status == .playing)
            #expect(env.rig.deviation(of: .b, from: 44100, at: 3 * Self.slice, count: 3 * Self.slice) == 0)
        }

        @Test("what was kept at quitting is what comes back")
        func roundTrip() async throws {
            let dir = try TempDir()
            let first = try await launch(in: dir, entries: standard())
            first.state.play(albumIndex: 0, trackIndex: 1)
            try await first.listen(1)
            await first.quit()
            let position = try #require(first.saved).position

            let second = try await launch(in: dir)
            await second.state.restorePlayback()
            #expect(second.state.status == .playing)
            #expect(second.state.info?.title == "A2")
            #expect(abs(second.state.position - position) < 0.001)
        }

        @Test("a track of a playlist that isn't the open one is picked up from that playlist")
        func otherPlaylist() async throws {
            let dir = try TempDir()
            let first = try await launch(in: dir, entries: standard())
            try first.store.create(named: "other")
            #expect(await waitUntil { !first.store.isLoading })
            await first.store.append(Make.albums([try entry(.c, title: "C1", album: "Z", track: 1)]), to: "other")
            first.store.setActive("main")
            let c1 = try first.id(of: "other", track: 0)
            first.config.update { $0.playback.state = Saved(playlist: "other", trackID: c1, position: 0.5, paused: false) }
            await first.quit()

            let second = try await launch(in: dir)
            await second.state.restorePlayback()
            #expect(second.store.activeName == "main")
            #expect(second.store.playingName == "other")
            #expect(second.state.info?.title == "C1")
            #expect(second.state.status == .playing)
            #expect(second.saved?.playlist == "other")
        }

        @Test("playback goes on in the playlist after the restored track, gaplessly, and ends with it")
        func restoreThenContinue() async throws {
            let dir = try await leftBehind { Saved(playlist: "main", trackID: try $0.id(track: 1), position: 2, paused: false) }
            let env = try await launch(in: dir)
            let a3 = try env.id(track: 2)
            await env.state.restorePlayback()
            #expect(env.state.info?.title == "A2")

            try await env.run(30_000)                                  // A2 has 0.5 s (22050 frames) left
            #expect(env.state.info?.title == "A3")
            #expect(env.saved?.trackID == a3)
            #expect(env.rig.deviation(of: .c, from: 0, at: 22_050, count: 5000) == 0)

            try await env.run(RampFile.c.frames)
            #expect(env.state.status == .stopped)                     // A3 was the last track
            #expect(env.saved == nil)
        }

        // MARK: Nothing to pick up

        @Test("nothing is restored with the setting off, and what was there is dropped by the next track")
        func restoreSettingOff() async throws {
            let dir = try await leftBehind { Saved(playlist: "main", trackID: try $0.id(track: 1), position: 1, paused: false) }
            let config = ConfigStore(paths: AppPaths(workDir: dir.path("work")), saveDelay: .seconds(60))
            config.update { $0.general.restorePlaybackState = false }
            config.flush()

            let env = try await launch(in: dir)
            #expect(!env.state.restoresState)
            await env.state.restorePlayback()
            #expect(env.state.status == .stopped)

            env.state.play(albumIndex: 0, trackIndex: 0)
            #expect(env.saved == nil)
        }

        @Test("nothing is restored when nothing was playing")
        func nothingPlaying() async throws {
            let env = try await launch(in: try TempDir(), entries: standard())
            await env.state.restorePlayback()
            #expect(env.state.status == .stopped)
            #expect(env.store.playingName == nil)
        }

        @Test("a track or a playlist that is gone is forgotten")
        func gone() async throws {
            let dir = try await leftBehind { _ in Saved(playlist: "main", trackID: 999, position: 1, paused: false) }
            let env = try await launch(in: dir)
            await env.state.restorePlayback()
            #expect(env.state.status == .stopped)
            #expect(env.saved == nil)

            env.config.update { $0.playback.state = Saved(playlist: "nope", trackID: 1, position: 1, paused: false) }
            await env.state.restorePlayback()
            #expect(env.state.status == .stopped)
            #expect(env.saved == nil)
        }

        @Test("a track that can't be played leaves playback stopped instead of going on to the ones after it")
        func unplayable() async throws {
            let entries = [Make.entry("/nonexistent/Gone.flac", artist: "Artist X", album: "X", title: "Gone", track: 1),
                           try entry(.b, title: "A2", track: 2)]
            let dir = try await leftBehind({ Saved(playlist: "main", trackID: try $0.id(track: 0), position: 1, paused: false) },
                                           entries: entries)
            let listener = RecordingListener()
            let env = try await launch(in: dir, listener: listener)
            await env.state.restorePlayback()
            try await env.run(4 * Self.slice)

            #expect(env.rig.events.contains("failed:Gone.flac:current"))
            #expect(env.state.status == .stopped)
            #expect(env.saved == nil)
            #expect(env.rig.firstSound() == nil)
            #expect(listener.events.isEmpty)
        }

        @Test("stopping while the playlist is still being read cancels the restore")
        func stopCancels() async throws {
            let dir = try await leftBehind { Saved(playlist: "main", trackID: try $0.id(track: 1), position: 1, paused: false) }
            let env = try await launch(in: dir, waitForPlaylists: false)
            let task = Task { await env.state.restorePlayback() }
            await Task.yield()                                         // the restore is waiting for the playlist now
            env.state.stop()                                           // forgets what was kept
            await task.value
            #expect(env.state.status == .stopped)
            #expect(env.store.playingName == nil)
            #expect(env.saved == nil)
        }

        // MARK: Scrobbling

        @Test("a track picked up from its second half counts as listened to; from its first half, from scratch")
        func listenedCredit() async throws {
            for (position, credited) in [(2.0, true), (1.0, false)] {
                let listener = RecordingListener()
                let dir = try await leftBehind { Saved(playlist: "main", trackID: try $0.id(track: 0), position: position, paused: false) }
                let env = try await launch(in: dir, listener: listener)
                await env.state.restorePlayback()
                try await env.run(Self.slice)                          // its audio starts
                #expect(listener.events == [.started("A1")])
                let started = try #require(listener.started.first)
                #expect(abs(started.startedAt.timeIntervalSinceNow + position) < 2)   // it started that long ago

                env.state.stop()
                let played = try #require(listener.ended.first).played
                if credited {
                    #expect(played >= RampFile.a.duration * LastFMService.scrobbleThreshold && played >= position,
                            "played \(played) of \(RampFile.a.duration)")
                } else {
                    #expect(played < 0.2, "played \(played)")
                }
            }
        }

        @Test("what is listened to after the pick-up is added to the credit, or counted on its own before half")
        func listenedAfterwards() async throws {
            // (picked up at, listened to since, counts as)
            for (position, since, expected) in [(1.0, 1.0, 1.0), (2.0, 0.5, 2.5)] {
                let listener = RecordingListener()
                let dir = try await leftBehind { Saved(playlist: "main", trackID: try $0.id(track: 0), position: position, paused: false) }
                let env = try await launch(in: dir, listener: listener)
                await env.state.restorePlayback()
                try await env.listen(since)
                env.state.stop()
                let played = try #require(listener.ended.first).played
                #expect(abs(played - expected) < 0.2, "picked up at \(position), played \(played)")
            }
        }

        @Test("a track quit and picked up again is only ended once: when it really is over")
        func endedOnce() async throws {
            let dir = try TempDir()
            let before = RecordingListener()
            let first = try await launch(in: dir, entries: standard(), listener: before)
            first.state.play(albumIndex: 0, trackIndex: 1)
            try await first.listen(1.6)                                // past half of A2 (2.5 s)
            await first.quit()
            #expect(before.ended.isEmpty)

            let after = RecordingListener()
            let second = try await launch(in: dir, listener: after)
            await second.state.restorePlayback()
            try await second.run(Self.slice)
            second.state.stop()
            let played = try #require(after.ended.first).played
            #expect(played >= RampFile.b.duration * LastFMService.scrobbleThreshold, "played \(played)")
        }
    }
}
