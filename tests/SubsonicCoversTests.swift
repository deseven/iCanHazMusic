// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Subsonic covers")
    struct SubsonicCoversTests {
        private struct Env {
            let root: URL
            let transport: StubTransport
            let service: SubsonicService
            let store: CoverStore
            let covers: SubsonicCovers
            let connection: UUID

            var requests: Int { transport.requests(for: "getCoverArt").count }

            /// The album of one song with cover id `art`, of the connection.
            func album(art: String? = "al-1_a") -> Album {
                let album = SubsonicAlbum(id: "al-1", name: "Arrival", artist: "Abba", year: 1976, songCount: 1, coverArt: art)
                let song = SubsonicSong(id: "s1", title: "Dancing Queen", album: "Arrival", albumID: "al-1", artist: "Abba", track: 1,
                                        disc: nil, year: nil, duration: 200, suffix: "flac", bitRate: 900, coverArt: art)
                return SubsonicImport.albums(of: [SubsonicPick(album: album, song: song)], connection: connection)[0]
            }

            func request(art: String? = "al-1_a") throws -> SubsonicCovers.Request {
                try #require(SubsonicCovers.Request(album: album(art: art)))
            }

            /// Files of the connection's `covers` directory.
            var files: [String] {
                let folder = AppPaths.subsonicDir(of: connection, in: root).appendingPathComponent(AppPaths.subsonicCoversDirName)
                return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            }
        }

        private func makeEnv(failing: Bool = false) throws -> Env {
            let root = try TempDir().path("subsonic")
            let config = ConfigStore(paths: AppPaths(workDir: try TempDir().path("work")), saveDelay: .seconds(60))
            let server = SubsonicStubServer()
            let transport = StubTransport { request, _ in
                if failing, request.url?.path == "/rest/getCoverArt.view" { return SubsonicAnswer.failed(code: 70, message: "Cover not found") }
                return try server.answer(request)
            }
            let service = SubsonicService(configStore: config, transport: transport, pingTransport: transport,
                                          covers: SubsonicCoverCache(directory: root), sleep: BlockingSleep().sleep, watchesNetwork: false)
            let home = SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://music.example.org", username: "bob", password: "pw")
            service.add(home)
            let store = CoverStore(url: try TempDir().path("covers.sqlite"), thumbnailPixels: AppConstants.coverThumbnailPixels)
            return Env(root: root, transport: transport, service: service, store: store,
                       covers: SubsonicCovers(service: service, thumbnails: store), connection: home.id)
        }

        @Test("only an album with a cover on a server has a request")
        func request() throws {
            let env = try makeEnv()
            let request = try env.request()
            #expect(request.connection == env.connection && request.albumID == "al-1" && request.art == "al-1_a")
            #expect(request.albumKey == env.album().key)
            #expect(SubsonicCovers.Request(album: env.album(art: nil)) == nil)
        }

        @Test("Now Playing's original is fetched once, kept as a file, and its thumbnail is stored")
        func original() async throws {
            let env = try makeEnv()
            var stored: [String] = []
            env.covers.onThumbnailStored = { stored.append($0) }
            let request = try env.request()

            let data = try #require(await env.covers.original(for: request))
            #expect(TestImages.inspect(data) != nil)
            #expect(env.requests == 1)
            #expect(env.transport.requests(for: "getCoverArt").first.flatMap { StubTransport.query(of: $0)["size"] } == "\(SubsonicCovers.originalSize)")
            #expect(env.files.count == 1)
            let thumbnail = try #require(env.store.data(for: request.albumKey))
            let info = try #require(TestImages.inspect(thumbnail))
            #expect(info.width == AppConstants.coverThumbnailPixels && info.height == AppConstants.coverThumbnailPixels)
            #expect(stored == [request.albumKey])

            // The next time: the file, no request, nothing stored again.
            #expect(await env.covers.original(for: request) == data)
            #expect(env.requests == 1 && stored.count == 1)
        }

        @Test("a thumbnail that is missing is made from the file on disk, without asking the server")
        func thumbnailFromFile() async throws {
            let env = try makeEnv()
            let request = try env.request()
            _ = await env.covers.original(for: request)
            #expect(env.requests == 1)

            let other = SubsonicCovers(service: env.service, thumbnails: CoverStore(url: try TempDir().path("covers2.sqlite"),
                                                                                    thumbnailPixels: AppConstants.coverThumbnailPixels))
            #expect(await other.ensureThumbnail(for: request))
            #expect(env.requests == 1)
        }

        @Test("an album block asks for a missing thumbnail once; a thumbnail that is there costs no request")
        func ensureThumbnail() async throws {
            let env = try makeEnv()
            let request = try env.request()

            #expect(await env.covers.ensureThumbnail(for: request))
            #expect(env.requests == 1 && env.store.data(for: request.albumKey) != nil)
            #expect(await env.covers.ensureThumbnail(for: request) == false)
            #expect(env.requests == 1)

            let there = try makeEnv()
            let known = try there.request()
            there.store.store(Data("thumbnail".utf8), for: known.albumKey)
            #expect(await there.covers.ensureThumbnail(for: known) == false)
            #expect(there.requests == 0 && there.files.isEmpty)
        }

        @Test("the same album is never fetched twice at once")
        func shared() async throws {
            let env = try makeEnv()
            let request = try env.request()
            async let first = env.covers.original(for: request)
            async let second = env.covers.ensureThumbnail(for: request)
            let (data, stored) = await (first, second)
            #expect(data != nil && stored)
            #expect(env.requests == 1)
        }

        @Test("a cover the server can't give is not tried again by album blocks, but is by the next play")
        func failure() async throws {
            let env = try makeEnv(failing: true)
            let request = try env.request()

            #expect(await env.covers.ensureThumbnail(for: request) == false)
            #expect(env.requests == 1)
            #expect(await env.covers.ensureThumbnail(for: request) == false)
            #expect(env.requests == 1)   // not again
            #expect(env.store.data(for: request.albumKey) == nil && env.files.isEmpty)

            #expect(await env.covers.original(for: request) == nil)
            #expect(env.requests == 2)   // a play tries again
        }

        @Test("reloading asks the server again and makes the thumbnail anew")
        func reload() async throws {
            let env = try makeEnv()
            let request = try env.request()
            _ = await env.covers.original(for: request)
            #expect(env.requests == 1)
            env.store.store(Data("old".utf8), for: request.albumKey)
            _ = await env.covers.original(for: request)
            #expect(env.requests == 1 && env.store.data(for: request.albumKey) == Data("old".utf8))   // from the file: left alone

            var stored: [String] = []
            env.covers.onThumbnailStored = { stored.append($0) }
            await env.covers.reload([request])
            #expect(env.requests == 2)
            let thumbnail = try #require(env.store.data(for: request.albumKey))
            #expect(thumbnail != Data("old".utf8) && TestImages.inspect(thumbnail) != nil)
            #expect(stored == [request.albumKey])
        }

        @Test("a changed cover id is fetched at the next play and replaces the thumbnail")
        func changedCover() async throws {
            let env = try makeEnv()
            let old = try env.request(art: "al-1_a")
            _ = await env.covers.original(for: old)
            #expect(env.requests == 1)

            let new = try env.request(art: "al-1_b")
            #expect(new.albumKey == old.albumKey)
            var stored: [String] = []
            env.covers.onThumbnailStored = { stored.append($0) }
            _ = await env.covers.original(for: new)
            #expect(env.requests == 2 && stored == [new.albumKey])
            #expect(env.files.count == 1)   // the stale file went
        }
    }
}
