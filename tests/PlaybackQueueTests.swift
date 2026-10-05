import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// The queue itself: what can be in it and how it follows changes of playlists and settings.
    @MainActor @Suite("PlaybackQueue")
    struct PlaybackQueueTests {
        private func q(_ playlist: String, _ id: TrackID) -> QueueEntry {
            QueueEntry(playlist: playlist, id: id)
        }

        private func q(_ id: TrackID) -> QueueEntry {
            q("main", id)
        }

        @Test("entries are appended in order, once, with their place")
        func append() {
            let queue = PlaybackQueue()
            #expect(queue.isEmpty)
            #expect(queue.append([q(3), q(1), q(3)]) == 2)
            #expect(queue.entries == [q(3), q(1)])
            #expect(queue.append([q(1), q(2)]) == 1)
            #expect(queue.entries == [q(3), q(1), q(2)])
            #expect(queue.position(of: q(3)) == 1)
            #expect(queue.position(of: q(2)) == 3)
            #expect(queue.position(of: q(9)) == nil)
            #expect(queue.contains(q(1)) && !queue.contains(q("other", 1)))
            #expect(queue.count == 3)
        }

        @Test("the same ID in another playlist is another track")
        func playlists() {
            let queue = PlaybackQueue()
            #expect(queue.append([q("a", 1), q("b", 1)]) == 2)
        }

        @Test("removing entries moves the others up")
        func remove() {
            let queue = PlaybackQueue()
            queue.append([q(1), q(2), q(3), q(4)])
            queue.remove([q(2), q(9)])
            #expect(queue.entries == [q(1), q(3), q(4)])
            #expect(queue.position(of: q(3)) == 2)
            queue.clear()
            #expect(queue.isEmpty && queue.position(of: q(1)) == nil)
        }

        @Test("a track that starts leaves the queue without a notification, everything else notifies")
        func notifications() {
            let queue = PlaybackQueue()
            var changes = 0
            queue.onChange = { changes += 1 }
            queue.append([q(1), q(2), q(3)])
            #expect(changes == 1)
            queue.append([q(1)])                          // nothing new
            #expect(changes == 1)
            #expect(queue.started(q(1)))
            #expect(!queue.started(q(1)))
            #expect(changes == 1)
            queue.remove([q(2)])
            #expect(changes == 2)
            queue.remove([q(9)])                          // nothing there
            #expect(changes == 2)
            queue.clear(notify: false)
            #expect(changes == 2 && queue.isEmpty)
            queue.append([q(1)])
            queue.clear()
            #expect(changes == 4)
            queue.stopAtEnd = true
            #expect(changes == 5)
        }

        @Test("turning the queue off empties it and nothing can be added")
        func disabled() {
            let queue = PlaybackQueue()
            queue.append([q(1)])
            queue.isEnabled = false
            #expect(queue.isEmpty)
            #expect(queue.append([q(2)]) == 0)
            #expect(queue.isEmpty)
            queue.isEnabled = true
            #expect(queue.append([q(2)]) == 1)
        }

        @Test("tracks removed from a playlist, a deleted playlist and a renamed one")
        func playlistChanges() {
            let queue = PlaybackQueue()
            queue.append([q("a", 1), q("b", 1), q("a", 2), q("b", 2)])
            queue.remove(ids: [1], fromPlaylist: "a")
            #expect(queue.entries == [q("b", 1), q("a", 2), q("b", 2)])
            queue.renamePlaylist(from: "b", to: "c")
            #expect(queue.entries == [q("c", 1), q("a", 2), q("c", 2)])
            queue.removeAll(inPlaylist: "c")
            #expect(queue.entries == [q("a", 2)])
        }

        @Test("the two settings are read from the config and kept in it")
        func settings() throws {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            #expect(config.config.general.queueEnabled)
            #expect(!config.config.playback.stopAtQueueEnd)

            let queue = PlaybackQueue(configStore: config)
            #expect(queue.isEnabled && !queue.stopAtEnd)
            queue.isEnabled = false
            queue.stopAtEnd = true
            #expect(!config.config.general.queueEnabled)
            #expect(config.config.playback.stopAtQueueEnd)

            let again = PlaybackQueue(configStore: config)
            #expect(!again.isEnabled && again.stopAtEnd)
        }
    }

    /// How playback follows the queue, and what drops it. Runs on an offline engine like `PlaybackStateTests`.
    @MainActor @Suite("PlaybackState queue")
    struct PlaybackQueueStateTests {
        private static let slice = PlaybackEngine.renderSlice

        @MainActor private struct Env {
            let dir: TempDir
            let store: PlaylistStore
            let rig: EngineRig
            let state: PlaybackState

            var queue: PlaybackQueue { state.queue }

            func run(_ frames: Int) async throws {
                try await rig.render(frames)
                state.tick()
            }

            /// The queue entry of a track of a playlist by title.
            func entry(_ title: String, in name: String = "main") throws -> QueueEntry {
                let playlist = try #require(store.playlist(named: name))
                let track = try #require(playlist.albums.flatMap(\.tracks).first { $0.title == title })
                return QueueEntry(playlist: name, id: track.id)
            }

            func enqueue(_ titles: String..., in name: String = "main") throws {
                state.enqueue(try titles.map { try entry($0, in: name) })
            }
        }

        private func entry(_ file: RampFile, title: String, album: String, track: Int) throws -> TrackEntry {
            Make.entry(try file.url().path, artist: "Artist \(album)", album: album, title: title, track: track)
        }

        /// Album "X": A1, A2, A3. Album "Y": B1, B2 (very short). A second playlist "other": C1.
        private func makeEnv(listener: PlaybackListener? = nil) async throws -> Env {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            let store = PlaylistStore(paths: paths, configStore: config)
            #expect(await waitUntil { !store.isLoading })
            await store.append(Make.albums([
                try entry(.a, title: "A1", album: "X", track: 1),
                try entry(.b, title: "A2", album: "X", track: 2),
                try entry(.c, title: "A3", album: "X", track: 3),
                try entry(.tiny, title: "B1", album: "Y", track: 1),
                try entry(.tiny2, title: "B2", album: "Y", track: 2),
            ]), to: "main")
            try store.create(named: "other")
            #expect(await waitUntil { !store.isLoading })
            await store.append(Make.albums([try entry(.c, title: "C1", album: "Z", track: 1)]), to: "other")
            store.setActive("main")

            let rig = EngineRig(lookahead: 60)
            let state = PlaybackState(store: store, engine: rig.engine, tickInterval: nil, positionStep: 0,
                                       listeners: listener.map { [$0] } ?? [])
            state.volume = 1
            let listener = rig.engine.onEvent
            rig.engine.onEvent = { [weak rig] event in
                rig?.record(event)
                listener?(event)
            }
            return Env(dir: dir, store: store, rig: rig, state: state)
        }

        // MARK: Following the queue

        @Test("next track plays the queued tracks one by one, then goes on after the last of them")
        func nextTrack() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("A3", "B1")
            #expect(env.queue.count == 2)

            env.state.nextTrack()
            #expect(env.state.info?.title == "A3")
            #expect(env.queue.entries == [try env.entry("B1")])            // the playing one is not in it
            env.state.nextTrack()
            #expect(env.state.info?.title == "B1")
            #expect(env.queue.isEmpty)
            env.state.nextTrack()                                          // on in the playlist: after B1
            #expect(env.state.info?.title == "B2")
        }

        @Test("the engine plays the queued track right after the current one, gapless")
        func gapless() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(4 * Self.slice)
            try env.enqueue("A3")
            try await env.run(RampFile.a.frames)
            #expect(env.state.info?.title == "A3")
            #expect(env.queue.isEmpty)
            let start = RampFile.a.frames
            #expect(env.rig.deviation(of: .c, from: 0, at: start, count: env.rig.frame - start) == 0)
        }

        @Test("a queue entered while the last track plays is played too")
        func enqueueLate() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 1, trackIndex: 1)                   // B2, the last track
            try env.enqueue("A2")
            try await env.run(RampFile.tiny2.frames + 4 * Self.slice)
            #expect(env.state.info?.title == "A2")
            #expect(env.state.status == .playing)
        }

        @Test("the playing track can't be queued, nor a track twice")
        func notTwice() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            let playing = try #require(env.state.playingEntry)
            #expect(playing == (try env.entry("A1")))
            #expect(env.state.enqueue([playing, try env.entry("A2")]) == 1)
            #expect(env.state.enqueue([try env.entry("A2")]) == 0)
            #expect(env.queue.entries == [try env.entry("A2")])
        }

        @Test("tracks of another playlist play, and playback moves over to that playlist")
        func otherPlaylist() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 1)
            try env.enqueue("C1", in: "other")
            try env.enqueue("A1")
            #expect(env.store.playingName == "main")

            env.state.nextTrack()
            #expect(env.state.info?.title == "C1")
            #expect(env.store.playingName == "other")
            #expect(env.store.activeName == "main")                        // what is shown stays
            #expect(env.queue.count == 1)

            env.state.nextTrack()                                          // back to a track of main
            #expect(env.state.info?.title == "A1")
            #expect(env.store.playingName == "main")
            env.state.nextTrack()                                          // goes on after A1 in main
            #expect(env.state.info?.title == "A2")
        }

        @Test("the queue wins over a track the cursor asked for")
        func overCursor() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("B2")
            env.state.cursorRow = 3                                        // a row of the playlist
            env.state.nextTrack()
            #expect(env.state.info?.title == "B2")
        }

        // MARK: Stop at queue end

        @Test("with Stop at queue end playback stops after the last queued track")
        func stopAtEnd() async throws {
            let listener = RecordingListener()
            let env = try await makeEnv(listener: listener)
            env.queue.stopAtEnd = true
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("A2")
            env.state.nextTrack()
            #expect(env.state.info?.title == "A2")
            #expect(listener.queuesEnded == 0)
            try await env.run(RampFile.b.frames + 4 * Self.slice)
            #expect(env.state.status == .stopped)
            #expect(listener.queuesEnded == 1)
            #expect(listener.playlistsEnded.isEmpty)
        }

        @Test("without it playback goes on in the playlist after the queue")
        func goesOn() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("A2")
            env.state.nextTrack()
            try await env.run(RampFile.b.frames + 4 * Self.slice)
            #expect(env.state.info?.title == "A3")
            #expect(env.state.status == .playing)
        }

        @Test("Stop at queue end only applies once a queued track has played")
        func stopAtEndNeedsQueue() async throws {
            let env = try await makeEnv()
            env.queue.stopAtEnd = true
            env.state.play(albumIndex: 0, trackIndex: 1)
            env.state.nextTrack()
            #expect(env.state.info?.title == "A3")                         // in order, as there was no queue
            env.state.nextTrack()
            #expect(env.state.info?.title == "B1")
        }

        @Test("next track on the last queued track stops with Stop at queue end")
        func nextAtEnd() async throws {
            let env = try await makeEnv()
            env.queue.stopAtEnd = true
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("A3")
            env.state.nextTrack()
            env.state.nextTrack()
            #expect(env.state.status == .stopped)
        }

        // MARK: Dropping the queue

        @Test("starting a track by hand drops the queue")
        func play() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("A3", "B1")
            env.state.play(albumIndex: 0, trackIndex: 1)
            #expect(env.queue.isEmpty)
            env.state.nextTrack()
            #expect(env.state.info?.title == "A3")                         // by the playlist, not the queue

            try env.enqueue("B2")
            env.state.play(row: 1)
            #expect(env.queue.isEmpty)
            try env.enqueue("B2")
            env.state.play(trackID: try env.entry("C1", in: "other").id, inPlaylist: "other")
            #expect(env.queue.isEmpty)
            #expect(env.state.info?.title == "C1")
        }

        @Test("stop, previous track and album, next album and the random ones drop the queue")
        func interference() async throws {
            let env = try await makeEnv()

            for action: (PlaybackState) -> Void in [
                { $0.stop() },
                { $0.previousTrack() },
                { $0.previousAlbum() },
                { $0.nextAlbum() },
                { $0.randomTrack() },
                { $0.randomAlbum() },
            ] {
                env.state.play(albumIndex: 0, trackIndex: 1)
                try env.enqueue("B1", "B2")
                #expect(env.queue.count == 2)
                action(env.state)
                #expect(env.queue.isEmpty)
            }
        }

        @Test("previous track goes by the playlist")
        func previous() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 1)
            try env.enqueue("B2")
            env.state.previousTrack()
            #expect(env.state.info?.title == "A1")

            env.state.play(albumIndex: 0, trackIndex: 1)
            try env.enqueue("B2")
            env.state.nextAlbum()
            #expect(env.state.info?.title == "B1")                         // the album, not the queued track
        }

        @Test("clearing the queue goes on in the playlist, also with Stop at queue end")
        func clear() async throws {
            let env = try await makeEnv()
            env.queue.stopAtEnd = true
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("A2")
            env.state.nextTrack()
            try env.enqueue("B2")
            env.state.clearQueue()
            #expect(env.queue.isEmpty)
            try await env.run(RampFile.b.frames + 4 * Self.slice)
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "A3")
        }

        @Test("removing entries changes what plays next")
        func dequeue() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("B2", "A3")
            env.state.dequeue([try env.entry("B2")])
            env.state.nextTrack()
            #expect(env.state.info?.title == "A3")
            #expect(env.queue.isEmpty)
        }

        // MARK: Starting from the queue

        @Test("play while stopped starts the queue, not the track under the cursor")
        func playStopped() async throws {
            let env = try await makeEnv()
            env.state.cursorRow = 1
            #expect(!env.state.hasQueuedTracks)
            try env.enqueue("B2", "A3")
            #expect(env.state.hasQueuedTracks && env.state.canPlay)

            env.state.playPause()
            #expect(env.state.status == .playing)
            #expect(env.state.info?.title == "B2")
            #expect(env.queue.entries == [try env.entry("A3")])
            #expect(env.store.playingName == "main")

            env.state.stop()
            #expect(env.queue.isEmpty)
            env.state.playPause()                                          // nothing queued: the cursor
            #expect(env.state.info?.title == "A1")
        }

        @Test("play while stopped starts a track of another playlist and moves over to it")
        func playStoppedOther() async throws {
            let env = try await makeEnv()
            try env.enqueue("C1", in: "other")
            env.state.resume()
            #expect(env.state.info?.title == "C1")
            #expect(env.store.playingName == "other")
        }

        // MARK: Playlists changing

        @Test("tracks removed from the playlist leave the queue")
        func removedTracks() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("A2", "B1", "B2")
            let removed = Set([try env.entry("A2").id, try env.entry("B2").id])
            await env.store.remove(ids: removed, from: "main")
            #expect(env.queue.entries == [try env.entry("B1")])
            env.state.nextTrack()
            #expect(env.state.info?.title == "B1")
        }

        @Test("a deleted playlist's tracks leave the queue, and playing one of them stops without dropping the rest")
        func deletedPlaylist() async throws {
            let env = try await makeEnv()
            env.state.play(trackID: try env.entry("C1", in: "other").id, inPlaylist: "other")
            try env.enqueue("A1", "B1")
            env.store.setActive("main")
            try await env.store.delete("other")
            #expect(env.state.status == .stopped)
            #expect(env.queue.entries == [try env.entry("A1"), try env.entry("B1")])

            env.state.playPause()                                          // the rest of the queue plays
            #expect(env.state.info?.title == "A1")
        }

        @Test("renaming a playlist keeps its tracks queued")
        func renamed() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("C1", in: "other")
            try await env.store.rename("other", to: "second")
            #expect(env.queue.entries.map(\.playlist) == ["second"])
            env.state.nextTrack()
            #expect(env.state.info?.title == "C1")
            #expect(env.store.playingName == "second")
        }

        @Test("with the queue turned off it is empty and playback follows the playlist")
        func turnedOff() async throws {
            let env = try await makeEnv()
            env.state.play(albumIndex: 0, trackIndex: 0)
            try env.enqueue("B2")
            env.queue.isEnabled = false
            #expect(env.queue.isEmpty)
            #expect(env.state.enqueue([try env.entry("B2")]) == 0)
            env.state.nextTrack()
            #expect(env.state.info?.title == "A2")
        }
    }
}
