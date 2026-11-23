// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Subsonic playlists")
    struct SubsonicPlaylistsTests {
        private final class Problems: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [(title: String, message: String)] = []
            var all: [(title: String, message: String)] { lock.withLock { list } }
            func add(_ title: String, _ message: String) { lock.withLock { list.append((title, message)) } }
        }

        /// An app run: a working directory, a connection, a server and everything built on them.
        @MainActor
        private struct Env {
            let dir: TempDir
            let paths: AppPaths
            let config: ConfigStore
            let connection: SubsonicConnectionConfig
            let server: SubsonicPlaylistServer
            let service: SubsonicService
            let store: PlaylistStore
            let playlists: SubsonicPlaylists
            let files: RecordingFileRemover
            let problems: Problems

            func id(_ remote: String) -> PlaylistID { .remote(connection: connection.id, id: remote) }

            var infos: [RemotePlaylistInfo] { store.remotePlaylists(of: connection.id) }

            /// Song IDs in the order the playlist is shown in.
            func songs(_ remote: String) -> [String] { store.playlist(id(remote))?.songIDs ?? [] }

            func trackIDs(_ remote: String) -> [String: TrackID] {
                Dictionary(uniqueKeysWithValues: (store.playlist(id(remote))?.entries ?? [])
                    .compactMap { entry in entry.subsonic.map { ($0.songID, entry.id) } })
            }

            var playlistsDir: URL { paths.subsonicPlaylistsDir(of: connection.id) }
        }

        private func makeEnv(_ playlists: [SubsonicPlaylistServer.Playlist] = [], reusing old: Env? = nil, down: Bool = false,
                             start: Bool = true) async throws -> Env {
            let dir = try old?.dir ?? TempDir()
            let paths = old?.paths ?? AppPaths(workDir: dir.path("work"))
            let connection = old?.connection ?? SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://music.example.org",
                                                                          username: "bob", password: "pw")
            let config = old?.config ?? ConfigStore(paths: paths, saveDelay: .seconds(60))
            if old == nil { config.update { $0.subsonic = [connection] } }
            let server = SubsonicPlaylistServer(playlists)
            server.setDown(down)
            let transport = server.transport
            let service = SubsonicService(configStore: config, transport: transport, pingTransport: transport,
                                          sleep: BlockingSleep().sleep, watchesNetwork: false)
            let store = PlaylistStore(paths: paths, configStore: config)
            let files = RecordingFileRemover()
            let remote = SubsonicPlaylists(store: store, service: service, files: files, sleep: BlockingSleep().sleep)
            let problems = Problems()
            remote.onProblem = { problems.add($0, $1) }
            let env = Env(dir: dir, paths: paths, config: config, connection: connection, server: server, service: service,
                          store: store, playlists: remote, files: files, problems: problems)
            if start { remote.start() }
            return env
        }

        private func playlist(_ id: String, _ name: String, _ songs: [String], owner: String = "bob",
                              readOnly: Bool = false) -> SubsonicPlaylistServer.Playlist {
            SubsonicPlaylistServer.Playlist(id: id, name: name, owner: owner, songs: songs, readOnly: readOnly)
        }

        /// Waits until every playlist of the connection is read from the server (and none has a change on its way).
        private func settled(_ env: Env, count: Int) async -> Bool {
            await waitUntil {
                env.infos.count == count && env.infos.allSatisfy { $0.synced != nil }
                    && env.infos.allSatisfy { env.store.playlist(env.id($0.id)) != nil }
                    && !env.playlists.state(of: env.connection.id).isBusy
            }
        }

        // MARK: Looking at the server

        @Test("the playlists of the server appear in a section of their own, flat, with their songs, and are cached")
        func firstSync() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1", "a2"]), playlist("p2", "Gym", ["c1"])])
            #expect(await settled(env, count: 2))

            #expect(env.store.remoteSections.map(\.name) == ["Home"])
            #expect(env.infos.map(\.name) == ["Gym", "Road"])
            #expect(env.store.names == ["main"])                          // the local ones are not touched
            #expect(env.songs("p1") == ["a1", "b1", "a2"])                // the order of the server, not grouped
            #expect(env.store.playlist(env.id("p1"))?.isFlat == true)
            #expect(env.playlists.state(of: env.connection.id).isOnline)
            #expect(env.store.canEdit(env.id("p1")))
            #expect(env.store.displayName(of: env.id("p1")) == "Road")
            #expect(env.store.qualifiedName(of: env.id("p1")) == "Road (Home)")

            await env.store.flushWrites()
            let files = (try? FileManager.default.contentsOfDirectory(atPath: env.playlistsDir.path)) ?? []
            #expect(files.contains("index.json"))
            #expect(files.filter { $0 != "index.json" }.count == 2)         // one file per playlist
        }

        @Test("a playlist that didn't change isn't read again; one that did is, and its tracks keep their IDs")
        func changes() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1", "a2"])])
            #expect(await settled(env, count: 1))
            let before = env.trackIDs("p1")
            #expect(env.server.requests("getPlaylist").count == 1)

            await env.playlists.refresh(env.connection.id)
            #expect(env.server.requests("getPlaylist").count == 1)       // nothing changed, one listing was enough

            env.server.change("p1", songs: ["a1", "a2", "d1"])
            await env.playlists.refresh(env.connection.id)
            #expect(env.songs("p1") == ["a1", "a2", "d1"])
            let after = env.trackIDs("p1")
            #expect(after["a1"] == before["a1"] && after["a2"] == before["a2"])
            #expect(after["d1"] != nil && !before.values.contains(after["d1"] ?? 0))
        }

        @Test("a song that is in the playlist twice keeps one ID per copy")
        func duplicates() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "a1"])])
            #expect(await settled(env, count: 1))
            let before = env.store.playlist(env.id("p1"))?.entries.map(\.id) ?? []
            #expect(before.count == 2 && Set(before).count == 2)

            env.server.change("p1", songs: ["a1", "b1", "a1"])
            await env.playlists.refresh(env.connection.id)
            let after = env.store.playlist(env.id("p1"))?.entries.map(\.id) ?? []
            #expect(after.count == 3 && after[0] == before[0] && after[2] == before[1])
        }

        @Test("a playlist that is gone from the server is deleted here, with the cached copy and the files of the songs no other playlist has")
        func gone() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1"]), playlist("p2", "Gym", ["b1", "c1"])])
            #expect(await settled(env, count: 2))
            env.store.setActive(env.id("p1"))
            await env.store.flushWrites()
            let file = env.playlistsDir.appendingPathComponent(RemotePlaylistIndex.fileName(of: "p1"))
            #expect(FileManager.default.fileExists(atPath: file.path))

            env.server.remove("p1")
            await env.playlists.refresh(env.connection.id)
            await env.store.flushWrites()
            #expect(env.infos.map(\.id) == ["p2"])
            #expect(!env.store.exists(env.id("p1")))
            #expect(env.store.activeID == "main")                         // a local one is opened instead
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(env.files.songIDs == ["a1"])                          // b1 is still in the other playlist
        }

        @Test("a new playlist on the server shows up with the next look")
        func appears() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1"])])
            #expect(await settled(env, count: 1))
            env.server.add(playlist("p2", "Gym", ["c1"]))
            await env.playlists.refresh(env.connection.id)
            #expect(env.infos.map(\.name) == ["Gym", "Road"])
            #expect(env.songs("p2") == ["c1"])
        }

        @Test("several playlists can have the same name")
        func sameNames() async throws {
            let env = try await makeEnv([playlist("p1", "Mix", ["a1"]), playlist("p2", "Mix", ["b1"])])
            #expect(await settled(env, count: 2))
            #expect(env.infos.map(\.name) == ["Mix", "Mix"])
            #expect(env.songs("p1") == ["a1"] && env.songs("p2") == ["b1"])
        }

        // MARK: Cache and server not reachable

        @Test("without the server the playlists come from the cache, read-only, with the reason; it is as usual when it is back")
        func offline() async throws {
            let first = try await makeEnv([playlist("p1", "Road", ["a1", "b1", "a2"])])
            #expect(await settled(first, count: 1))
            await first.store.flushWrites()

            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1", "a2"])], reusing: first, down: true)
            #expect(env.infos.map(\.name) == ["Road"])                    // there before anything was asked
            #expect(await env.store.readPlaylist(env.id("p1"))?.songIDs == ["a1", "b1", "a2"])
            #expect(await waitUntil { env.playlists.state(of: env.connection.id).error != nil })
            #expect(!env.store.canEdit(env.id("p1")))
            #expect(env.playlists.readOnlyReason(env.id("p1"))?.contains("can't be reached") == true)

            env.server.setDown(false)
            await env.playlists.refresh(env.connection.id)
            #expect(env.playlists.state(of: env.connection.id).isOnline)
            #expect(env.store.canEdit(env.id("p1")))
            #expect(env.playlists.readOnlyReason(env.id("p1")) == nil)
        }

        @Test("a playlist is read-only until it was read from the server once")
        func neverRead() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1"])], start: false)
            #expect(env.infos.isEmpty)                                    // nothing cached yet
            env.playlists.start()
            #expect(await waitUntil { env.infos.count == 1 })
            #expect(await settled(env, count: 1))
            #expect(env.store.canEdit(env.id("p1")))
        }

        @Test("a connection that is switched off hides its playlists; a local one opens if one of them was shown")
        func switchedOff() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1"])])
            #expect(await settled(env, count: 1))
            env.store.setActive(env.id("p1"))
            #expect(env.store.activeID == env.id("p1"))

            env.service.setEnabled(false, for: env.connection.id)
            #expect(env.store.remoteSections.isEmpty)
            #expect(env.store.activeID == "main")
            #expect(env.store.count == 1)
            #expect(env.store.playlist(env.id("p1")) == nil)

            env.service.setEnabled(true, for: env.connection.id)            // the cache is still there
            #expect(env.infos.map(\.name) == ["Road"])
            #expect(await settled(env, count: 1))
        }

        // MARK: Read-only

        @Test("somebody else's playlist and a read-only one play but can't be changed, and say why")
        func readOnly() async throws {
            let env = try await makeEnv([playlist("p1", "Theirs", ["a1", "b1"], owner: "alice"),
                                         playlist("p2", "Smart", ["c1"], readOnly: true),
                                         playlist("p3", "Mine", ["d1"])])
            #expect(await settled(env, count: 3))
            #expect(!env.store.canEdit(env.id("p1")) && !env.store.canEdit(env.id("p2")) && env.store.canEdit(env.id("p3")))
            #expect(env.playlists.readOnlyReason(env.id("p1"))?.contains("alice") == true)
            #expect(env.infos.first { $0.id == "p1" }?.isForeign == true)

            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()
            let ids = Set(env.trackIDs("p1").values)
            await env.store.remove(ids: ids, from: env.id("p1"))
            #expect(env.songs("p1") == ["a1", "b1"])
            #expect(!env.store.moveAlbum(0, to: 1, in: env.id("p1")))
            #expect(env.server.requests("createPlaylist").isEmpty && env.server.requests("updatePlaylist").isEmpty)
            await #expect(throws: (any Error).self) { try await env.playlists.renamePlaylist(env.id("p1"), to: "Mine now") }
            await #expect(throws: (any Error).self) { try await env.playlists.deletePlaylist(env.id("p2")) }
            #expect(env.server.playlists.count == 3)
        }

        // MARK: Changes

        @Test("removing a track sets the server's playlist to what is shown: the whole order, sent as a POST with no credentials in the URL")
        func removing() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1", "a2"])])
            #expect(await settled(env, count: 1))
            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()
            let b1 = try #require(env.trackIDs("p1")["b1"])

            await env.store.remove(ids: [b1], from: env.id("p1"))
            #expect(env.songs("p1") == ["a1", "a2"])                      // at once
            #expect(await waitUntil { env.server.playlist("p1")?.songs == ["a1", "a2"] && env.infos.first?.synced == "c2" })

            let sent = try #require(env.server.requests("createPlaylist").first)
            #expect(sent.isPost && sent.url.query == nil)
            #expect(sent.value("playlistId") == "p1" && sent.values("songId") == ["a1", "a2"])
            #expect(sent.value("u") == "bob" && sent.value("t") != nil && sent.value("s") != nil)
            #expect(env.store.canEdit(env.id("p1")))                      // confirmed, editable again
            #expect(env.problems.all.isEmpty)
        }

        @Test("moving an album or a track changes the order on the server")
        func moving() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1", "c1"])])
            #expect(await settled(env, count: 1))
            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()

            #expect(env.store.moveAlbum(2, to: 0, in: env.id("p1")))      // flat: a track
            #expect(env.songs("p1") == ["c1", "a1", "b1"])
            #expect(await waitUntil { env.server.playlist("p1")?.songs == ["c1", "a1", "b1"] && env.infos.first?.synced == "c2" })
        }

        @Test("quitting waits for what is on its way to the server")
        func flushing() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1"])])
            #expect(await settled(env, count: 1))
            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()

            await env.store.remove(ids: [try #require(env.trackIDs("p1")["a1"])], from: env.id("p1"))
            #expect(env.playlists.hasPendingEdits)
            await env.playlists.flushEdits()
            #expect(!env.playlists.hasPendingEdits)
            #expect(env.server.playlist("p1")?.songs == ["b1"])
        }

        @Test("several quick changes end with the server having the last state")
        func quickChanges() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1", "c1", "d1"])])
            #expect(await settled(env, count: 1))
            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()

            #expect(env.store.moveAlbum(3, to: 0, in: env.id("p1")))
            #expect(env.store.moveAlbum(1, to: 3, in: env.id("p1")))
            let shown = env.songs("p1")
            #expect(await waitUntil { env.server.playlist("p1")?.songs == shown && env.infos.first?.synced != nil })
            #expect(env.songs("p1") == shown)
            #expect(env.problems.all.isEmpty)
        }

        @Test("a change made from an older version of the playlist is dropped, the user is told, and the playlist is the server's")
        func conflict() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1", "a2"])])
            #expect(await settled(env, count: 1))
            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()
            let b1 = try #require(env.trackIDs("p1")["b1"])

            env.server.change("p1", songs: ["a1", "b1", "a2", "z1"])      // somebody else, since the last look
            await env.store.remove(ids: [b1], from: env.id("p1"))
            #expect(await waitUntil { !env.problems.all.isEmpty })
            #expect(env.problems.all.first?.title == "Playlist Changed")
            #expect(await waitUntil { env.songs("p1") == ["a1", "b1", "a2", "z1"] })
            #expect(env.server.playlist("p1")?.songs == ["a1", "b1", "a2", "z1"])
            #expect(env.server.requests("createPlaylist").isEmpty)
        }

        @Test("a change that the server doesn't take is reported, and the playlist is read again")
        func failed() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1"])])
            #expect(await settled(env, count: 1))
            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()

            env.server.setDown(true)
            // The playlist can't be changed while the server is down, but it was up when this was started.
            await env.store.remove(ids: [try #require(env.trackIDs("p1")["a1"])], from: env.id("p1"))
            #expect(await waitUntil { !env.problems.all.isEmpty })
            #expect(env.problems.all.first?.title == "Playlist Not Saved")

            env.server.setDown(false)
            await env.playlists.refresh(env.connection.id)
            #expect(await waitUntil { env.songs("p1") == ["a1", "b1"] })   // the server's version is back
        }

        @Test("a server that doesn't take POST is asked with a GET")
        func getFallback() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1"])])
            #expect(await settled(env, count: 1))
            env.server.setPostAllowed(false)
            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()

            await env.store.remove(ids: [try #require(env.trackIDs("p1")["a1"])], from: env.id("p1"))
            #expect(await waitUntil { env.server.playlist("p1")?.songs == ["b1"] })
            let sent = try #require(env.server.requests("createPlaylist").first)
            #expect(!sent.isPost && sent.values("songId") == ["b1"])
        }

        // MARK: Grouping

        @Test("grouping a playlist by albums puts the tracks of an album together on the server too; flat again leaves it")
        func grouping() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1", "a2"])])
            #expect(await settled(env, count: 1))
            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()
            #expect(env.store.activePlaylist.isFlat)

            await env.store.setFlat(false)
            #expect(env.songs("p1") == ["a1", "a2", "b1"])
            #expect(await waitUntil { env.server.playlist("p1")?.songs == ["a1", "a2", "b1"] && env.infos.first?.synced == "c2" })
            #expect(env.server.requests("createPlaylist").count == 1)

            await env.store.setFlat(true)
            #expect(env.songs("p1") == ["a1", "a2", "b1"])                // the order stays
            await env.playlists.refresh(env.connection.id)
            #expect(env.server.requests("createPlaylist").count == 1)     // nothing more was sent
        }

        @Test("grouping isn't done to a playlist that can't be changed on the server (it is only shown grouped), nor while it is out of reach")
        func groupingReadOnly() async throws {
            let env = try await makeEnv([playlist("p1", "Theirs", ["a1", "b1", "a2"], owner: "alice"),
                                         playlist("p2", "Mine", ["a1", "b1", "a2"])])
            #expect(await settled(env, count: 2))

            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()
            await env.store.setFlat(false)
            #expect(env.songs("p1") == ["a1", "a2", "b1"])
            await env.playlists.refresh(env.connection.id)
            #expect(env.server.playlist("p1")?.songs == ["a1", "b1", "a2"])   // theirs stays as it is
            #expect(env.server.requests("createPlaylist").isEmpty)

            env.store.setActive(env.id("p2"))
            await env.store.waitUntilLoaded()
            #expect(await waitUntil { !env.playlists.state(of: env.connection.id).isBusy })   // what opening it asked for
            env.server.setDown(true)
            await env.playlists.refresh(env.connection.id)
            #expect(!env.store.canEdit(env.id("p2")))
            await env.store.setFlat(false)
            #expect(env.store.activePlaylist.isFlat)                      // refused: it would reorder it later
        }

        @Test("a grouped playlist whose order on the server differs gets the grouped order, once")
        func regrouping() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "a2"])])
            #expect(await settled(env, count: 1))
            env.store.setActive(env.id("p1"))
            await env.store.waitUntilLoaded()
            await env.store.setFlat(false)                                // already in album order: nothing to send
            #expect(env.server.requests("createPlaylist").isEmpty)

            env.server.change("p1", songs: ["a1", "b1", "a2"])            // another client adds a song of another album
            await env.playlists.refresh(env.connection.id)
            #expect(await waitUntil { env.server.playlist("p1")?.songs == ["a1", "a2", "b1"] && env.infos.first?.synced == "c3" })
            #expect(env.songs("p1") == ["a1", "a2", "b1"])
            #expect(env.server.requests("createPlaylist").count == 1)

            await env.playlists.refresh(env.connection.id)
            #expect(env.server.requests("createPlaylist").count == 1)
        }

        // MARK: Making, renaming, deleting

        @Test("a new playlist is made on the server, private, and opens empty and flat; names can repeat")
        func creating() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1"])])
            #expect(await settled(env, count: 1))

            try await env.playlists.createPlaylist(named: "  Mix ", on: env.connection.id)
            let made = try #require(env.server.playlists.first { $0.name == "Mix" })
            #expect(env.infos.map(\.name) == ["Mix", "Road"])
            #expect(env.store.activeID == env.id(made.id))
            #expect(env.store.activePlaylist.trackCount == 0 && env.store.activePlaylist.isFlat)
            #expect(env.store.canEdit(env.id(made.id)))
            let sent = try #require(env.server.requests("createPlaylist").first)
            #expect(sent.isPost && sent.value("name") == "Mix" && sent.value("public") == nil)

            try await env.playlists.createPlaylist(named: "Mix", on: env.connection.id)
            #expect(env.infos.map(\.name) == ["Mix", "Mix", "Road"])

            await #expect(throws: PlaylistError.self) { try await env.playlists.createPlaylist(named: "  ", on: env.connection.id) }
            await env.playlists.refresh(env.connection.id)                // the server's list has both: nothing is lost
            #expect(env.infos.count == 3)
        }

        @Test("a playlist can't be made on a server that can't be reached")
        func creatingOffline() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1"])])
            #expect(await settled(env, count: 1))
            env.server.setDown(true)
            await #expect(throws: SubsonicError.self) { try await env.playlists.createPlaylist(named: "Mix", on: env.connection.id) }
            #expect(env.infos.map(\.name) == ["Road"])
        }

        @Test("renaming goes to the server first, and the playlist keeps its place in the queue and everything else")
        func renaming() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1"])])
            #expect(await settled(env, count: 1))
            let before = env.trackIDs("p1")

            try await env.playlists.renamePlaylist(env.id("p1"), to: " Trip ")
            #expect(env.server.playlist("p1")?.name == "Trip")
            #expect(env.store.displayName(of: env.id("p1")) == "Trip")
            #expect(env.trackIDs("p1") == before)
            #expect(await waitUntil { env.infos.first?.synced == env.infos.first?.changed })
            let sent = try #require(env.server.requests("updatePlaylist").first)
            #expect(sent.isPost && sent.value("playlistId") == "p1" && sent.value("name") == "Trip")
        }

        @Test("deleting goes to the server, then removes the cached copy and the files of the songs no other playlist has")
        func deleting() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1", "b1"]), playlist("p2", "Gym", ["b1", "c1"])])
            #expect(await settled(env, count: 2))
            env.store.setActive(env.id("p1"))
            await env.store.flushWrites()
            let file = env.playlistsDir.appendingPathComponent(RemotePlaylistIndex.fileName(of: "p1"))
            #expect(FileManager.default.fileExists(atPath: file.path))

            try await env.playlists.deletePlaylist(env.id("p1"))
            await env.store.flushWrites()
            #expect(env.server.playlists.map(\.id) == ["p2"])
            #expect(env.infos.map(\.id) == ["p2"])
            #expect(env.store.activeID == "main")
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(env.files.songIDs == ["a1"])
            #expect(env.server.requests("deletePlaylist").first?.isPost == true)

            await env.playlists.refresh(env.connection.id)
            #expect(env.infos.map(\.id) == ["p2"])
        }

        @Test("songs are added at the end of the playlist on the server, then shown")
        func appending() async throws {
            let env = try await makeEnv([playlist("p1", "Road", ["a1"])])
            #expect(await settled(env, count: 1))
            let before = env.trackIDs("p1")

            try await env.playlists.append(songIDs: ["c1", "c2"], to: env.id("p1"))
            #expect(env.server.playlist("p1")?.songs == ["a1", "c1", "c2"])
            #expect(env.songs("p1") == ["a1", "c1", "c2"])
            #expect(env.trackIDs("p1")["a1"] == before["a1"])
            let sent = try #require(env.server.requests("updatePlaylist").first)
            #expect(sent.isPost && sent.values("songIdToAdd") == ["c1", "c2"])
        }

        @Test("songs can't be added to a playlist that is read-only")
        func appendingReadOnly() async throws {
            let env = try await makeEnv([playlist("p1", "Theirs", ["a1"], owner: "alice")])
            #expect(await settled(env, count: 1))
            await #expect(throws: SubsonicError.self) { try await env.playlists.append(songIDs: ["c1"], to: env.id("p1")) }
            #expect(env.server.playlist("p1")?.songs == ["a1"])
        }
    }
}
