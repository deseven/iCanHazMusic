// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Subsonic automatic downloads")
    struct SubsonicAutoDownloadsTests {
        /// The transfers of the downloads: every song is a few bytes, those in `failing` can't be had.
        private final class Transfers: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [URL] = []
            private var failingSongs = Set<String>()

            var calls: [String] { lock.withLock { urls.map(\.lastPathComponent) } }
            func setFailing(_ songs: Set<String>) { lock.withLock { failingSongs = songs } }

            var transfer: SubsonicDownloads.Transfer {
                { [self] from, to, _ in
                    let fails = lock.withLock {
                        urls.append(from)
                        return failingSongs.contains(from.lastPathComponent)
                    }
                    if fails { throw SubsonicError(.notFound, "no such song") }
                    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("1234".utf8).write(to: to)
                }
            }
        }

        @MainActor
        private struct Env {
            let dir: TempDir
            let paths: AppPaths
            let config: ConfigStore
            let connection: SubsonicConnectionConfig
            let server: SubsonicPlaylistServer
            let store: PlaylistStore
            let playlists: SubsonicPlaylists
            let downloads: SubsonicDownloads
            let auto: SubsonicAutoDownloads
            let transfers: Transfers

            func id(_ remote: String) -> PlaylistID { .remote(connection: connection.id, id: remote) }

            func ref(_ song: String) -> SubsonicRef { SubsonicRef(connection: connection.id, songID: song, suffix: "mp3") }

            /// The songs whose file is in the cache.
            var downloaded: Set<String> {
                let names = Set((try? FileManager.default.contentsOfDirectory(
                    atPath: paths.subsonicCacheDir.appendingPathComponent("\(connection.id.uuidString)/downloads").path)) ?? [])
                return Set(["a1", "a2", "b1", "c1", "d1"].filter { names.contains(SubsonicDownloads.fileName(of: ref($0))) })
            }

            func progress(_ remote: String) -> SubsonicAutoDownloads.Progress? { auto.progress[id(remote)] }
        }

        private func makeEnv(_ playlists: [SubsonicPlaylistServer.Playlist], cache: SubsonicCacheSize = .off,
                             reusing old: Env? = nil) async throws -> Env {
            let dir = try old?.dir ?? TempDir()
            let paths = old?.paths ?? AppPaths(workDir: dir.path("work"))
            var connection = old?.connection ?? SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://music.example.org",
                                                                          username: "bob", password: "pw")
            connection.cacheSize = cache
            let config = old?.config ?? ConfigStore(paths: paths, saveDelay: .seconds(60))
            config.update { $0.subsonic = [connection] }
            let server = SubsonicPlaylistServer(playlists)
            let service = SubsonicService(configStore: config, transport: server.transport, pingTransport: server.transport,
                                          sleep: BlockingSleep().sleep, watchesNetwork: false)
            let transfers = Transfers()
            let downloads = SubsonicDownloads(directory: paths.subsonicCacheDir, provider: FakeDownloadProvider(),
                                              transfer: transfers.transfer)
            downloads.setCachePolicies([connection.id: cache])
            let store = PlaylistStore(paths: paths, configStore: config)
            let remote = SubsonicPlaylists(store: store, service: service, files: downloads, sleep: BlockingSleep().sleep)
            let auto = SubsonicAutoDownloads(store: store, service: service, downloads: downloads)
            remote.watcher = auto
            remote.start()
            let env = Env(dir: dir, paths: paths, config: config, connection: connection, server: server, store: store,
                          playlists: remote, downloads: downloads, auto: auto, transfers: transfers)
            #expect(await waitUntil {
                let infos = store.remotePlaylists(of: connection.id)
                return infos.count == playlists.count && infos.allSatisfy { $0.synced != nil && store.playlist(env.id($0.id)) != nil }
                    && !remote.state(of: connection.id).isBusy
            })
            return env
        }

        private func playlist(_ id: String, _ songs: [String]) -> SubsonicPlaylistServer.Playlist {
            SubsonicPlaylistServer.Playlist(id: id, name: id, songs: songs)
        }

        @Test("turning it on downloads every song of the playlist once and keeps them without a cache, with the progress")
        func download() async throws {
            let env = try await makeEnv([playlist("p1", ["a1", "b1", "a1"]), playlist("p2", ["c1"])])
            #expect(env.progress("p1") == nil)

            await env.auto.setEnabled(true, for: env.id("p1"))
            #expect(env.store.remoteInfo(env.id("p1"))?.autoDownload == true)
            #expect(await waitUntil { env.progress("p1") == .init(downloaded: 2, total: 2) && env.auto.downloading.isEmpty })
            #expect(env.downloaded == ["a1", "b1"])
            #expect(env.transfers.calls.sorted() == ["a1", "b1"])
            #expect(env.progress("p2") == nil)
            #expect(env.downloads.count == 0)   // nothing holds them, they are pinned

            // Nothing changed: the next look at the server downloads nothing.
            await env.playlists.refresh(env.connection.id)
            #expect(env.transfers.calls.count == 2)
        }

        @Test("songs added on the server are downloaded with the next look, removed ones become ordinary downloads")
        func follows() async throws {
            let env = try await makeEnv([playlist("p1", ["a1", "b1"])])
            await env.auto.setEnabled(true, for: env.id("p1"))
            #expect(await waitUntil { env.progress("p1")?.isComplete == true && env.auto.downloading.isEmpty })

            env.server.change("p1", songs: ["a1", "d1"])
            await env.playlists.refresh(env.connection.id)
            #expect(await waitUntil { env.downloaded == ["a1", "d1"] })   // b1 has no cache to stay in
            #expect(await waitUntil { env.progress("p1") == .init(downloaded: 2, total: 2) })
        }

        @Test("turning it off leaves the files to the cache size, and the setting survives a look at the server and a new run")
        func turningOff() async throws {
            let env = try await makeEnv([playlist("p1", ["a1", "b1"])])
            await env.auto.setEnabled(true, for: env.id("p1"))
            #expect(await waitUntil { env.progress("p1")?.isComplete == true && env.auto.downloading.isEmpty })

            env.server.change("p1", songs: ["a1", "b1"])   // a new version: read again
            await env.playlists.refresh(env.connection.id)
            #expect(env.store.remoteInfo(env.id("p1"))?.autoDownload == true)
            await env.store.flushWrites()
            let again = try await makeEnv([playlist("p1", ["a1", "b1"])], reusing: env)
            #expect(again.store.remoteInfo(again.id("p1"))?.autoDownload == true)
            #expect(await waitUntil { again.progress("p1")?.isComplete == true })
            #expect(again.transfers.calls.isEmpty)   // all there from the earlier run

            await again.auto.setEnabled(false, for: again.id("p1"))
            #expect(again.progress("p1") == nil)
            #expect(again.downloads.pinnedFiles(of: again.connection.id).isEmpty)
            #expect(await waitUntil { again.downloaded.isEmpty })
        }

        @Test("with a cache that has a size the files of a playlist that is no longer downloaded stay until it is full")
        func turningOffWithCache() async throws {
            let env = try await makeEnv([playlist("p1", ["a1", "b1"])], cache: .limited(gigabytes: 5))
            await env.auto.setEnabled(true, for: env.id("p1"))
            #expect(await waitUntil { env.progress("p1")?.isComplete == true && env.auto.downloading.isEmpty })
            await env.auto.setEnabled(false, for: env.id("p1"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(env.downloaded == ["a1", "b1"])
        }

        @Test("the files of a playlist that is deleted go, those another playlist that is downloaded has stay")
        func deleted() async throws {
            let env = try await makeEnv([playlist("p1", ["a1", "b1"]), playlist("p2", ["b1"])], cache: .unlimited)
            await env.auto.setEnabled(true, for: env.id("p1"))
            await env.auto.setEnabled(true, for: env.id("p2"))
            #expect(await waitUntil { env.progress("p1")?.isComplete == true && env.progress("p2")?.isComplete == true })

            env.server.remove("p1")
            await env.playlists.refresh(env.connection.id)
            #expect(env.downloaded == ["b1"])
            #expect(env.progress("p1") == nil && env.progress("p2")?.isComplete == true)
        }

        @Test("a song that can't be had is tried again with the next look at the server")
        func retry() async throws {
            let env = try await makeEnv([playlist("p1", ["a1", "b1"])])
            env.transfers.setFailing(["b1"])
            await env.auto.setEnabled(true, for: env.id("p1"))
            #expect(await waitUntil { env.progress("p1") == .init(downloaded: 1, total: 2) && env.auto.downloading.isEmpty })

            env.transfers.setFailing([])
            await env.playlists.refresh(env.connection.id)
            #expect(await waitUntil { env.progress("p1")?.isComplete == true })
            #expect(env.downloaded == ["a1", "b1"])
        }

        @Test("downloading stops after a few failures in a row")
        func givesUp() async throws {
            let env = try await makeEnv([playlist("p1", ["a1", "a2", "b1", "c1", "d1"])])
            env.transfers.setFailing(["a1", "a2", "b1", "c1", "d1"])
            await env.auto.setEnabled(true, for: env.id("p1"))
            #expect(await waitUntil { env.auto.downloading.isEmpty && !env.transfers.calls.isEmpty })
            try await Task.sleep(for: .milliseconds(100))
            #expect(env.transfers.calls.count < 5)
            #expect(env.progress("p1") == .init(downloaded: 0, total: 5))
        }
    }
}
