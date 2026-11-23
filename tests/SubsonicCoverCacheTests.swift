// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Subsonic cover cache")
    struct SubsonicCoverCacheTests {
        private let connection = UUID(uuidString: "0F6C3A3E-52E8-4F1B-9C9C-6A1E3B8D7A11")!
        private let png = TestImages.make(width: 40, height: 40)

        private func files(_ root: URL, of connection: UUID) -> [String] {
            let folder = AppPaths.subsonicDir(of: connection, in: root).appendingPathComponent(AppPaths.subsonicCoversDirName)
            return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }

        @Test("a cover is kept per album, the album's other cover id is stale, and no cover id of another album is touched")
        func cache() throws {
            let root = try TempDir().path("subsonic")
            let cache = SubsonicCoverCache(directory: root)
            #expect(cache.lookup(connection: connection, album: "al-1", art: "al-1", size: 1200) == nil)

            cache.store(png, connection: connection, album: "al-1", art: "al-1_a", size: 1200)
            cache.store(png, connection: connection, album: "al-2", art: "al-2_a", size: 1200)
            #expect(cache.lookup(connection: connection, album: "al-1", art: "al-1_a", size: 1200) == SubsonicCoverCache.Hit(data: png, isCurrent: true))
            #expect(cache.lookup(connection: connection, album: "al-1", art: "al-1_b", size: 1200) == SubsonicCoverCache.Hit(data: png, isCurrent: false))
            #expect(cache.lookup(connection: connection, album: "al-3", art: "al-3_a", size: 1200) == nil)
            #expect(cache.lookup(connection: UUID(), album: "al-1", art: "al-1_a", size: 1200) == nil)

            // A new cover replaces the old one of the same album only.
            let other = TestImages.make(width: 20, height: 30)
            cache.store(other, connection: connection, album: "al-1", art: "al-1_b", size: 1200)
            #expect(files(root, of: connection).count == 2)
            #expect(cache.lookup(connection: connection, album: "al-1", art: "al-1_b", size: 1200)?.data == other)
            #expect(cache.lookup(connection: connection, album: "al-2", art: "al-2_a", size: 1200)?.isCurrent == true)
        }

        @Test("something that isn't an image is not kept")
        func notAnImage() throws {
            let root = try TempDir().path("subsonic")
            let cache = SubsonicCoverCache(directory: root)
            cache.store(Data("<html>nope</html>".utf8), connection: connection, album: "al-1", art: "x", size: nil)
            #expect(files(root, of: connection).isEmpty)
        }

        @Test("the service asks the server once, then answers from disk, also when the server is gone or the connection is off")
        func service() async throws {
            let root = try TempDir().path("subsonic")
            let config = ConfigStore(paths: AppPaths(workDir: try TempDir().path("work")), saveDelay: .seconds(60))
            let server = SubsonicStubServer()
            let transport = server.transport
            let service = SubsonicService(configStore: config, transport: transport, pingTransport: transport,
                                          covers: SubsonicCoverCache(directory: root), sleep: BlockingSleep().sleep, watchesNetwork: false)
            let home = SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://music.example.org", username: "bob", password: "pw")
            service.add(home)

            let first = await service.coverArt(connection: home.id, album: "al-1", id: "al-1_a", size: 1200)
            #expect(first != nil)
            #expect(await waitUntil { files(root, of: home.id).count == 1 })
            #expect(transport.requests(for: "getCoverArt").count == 1)

            #expect(await service.coverArt(connection: home.id, album: "al-1", id: "al-1_a", size: 1200) == first)
            #expect(transport.requests(for: "getCoverArt").count == 1)

            // The cover changed on the server, which is not reachable: the old one is better than none.
            server.setDown("music.example.org", true)
            #expect(await service.coverArt(connection: home.id, album: "al-1", id: "al-1_b", size: 1200) == first)
            // Another album has nothing.
            #expect(await service.coverArt(connection: home.id, album: "al-2", id: "al-2_a", size: 1200) == nil)

            service.setEnabled(false, for: home.id)
            #expect(await service.coverArt(connection: home.id, album: "al-1", id: "al-1_a", size: 1200) == first)
        }

        @Test("a failing server leaves nothing behind")
        func failing() async throws {
            let root = try TempDir().path("subsonic")
            let config = ConfigStore(paths: AppPaths(workDir: try TempDir().path("work")), saveDelay: .seconds(60))
            let server = SubsonicStubServer()
            let transport = StubTransport { request, _ in
                request.url?.path == "/rest/getCoverArt.view" ? SubsonicAnswer.failed(code: 70, message: "Cover not found") : try server.answer(request)
            }
            let service = SubsonicService(configStore: config, transport: transport, pingTransport: transport,
                                          covers: SubsonicCoverCache(directory: root), sleep: BlockingSleep().sleep, watchesNetwork: false)
            let home = SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://music.example.org", username: "bob", password: "pw")
            service.add(home)

            #expect(await service.coverArt(connection: home.id, album: "al-1", id: "al-1", size: 1200) == nil)
            #expect(files(root, of: home.id).isEmpty)
        }
    }
}
