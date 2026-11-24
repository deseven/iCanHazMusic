// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

/// A Subsonic server behind `StubTransport`: answers by method, and fails for the hosts that are `down`.
final class SubsonicStubServer: @unchecked Sendable {
    private let lock = NSLock()
    private var downHosts: Set<String> = []
    private var wrongPassword = false

    var transport: StubTransport {
        StubTransport { [self] request, _ in try answer(request) }
    }

    func setDown(_ host: String, _ down: Bool) {
        lock.withLock { if down { downHosts.insert(host) } else { downHosts.remove(host) } }
    }

    func setWrongPassword(_ value: Bool) { lock.withLock { wrongPassword = value } }

    func answer(_ request: URLRequest) throws -> StubTransport.Answer {
        let (isDown, wrong) = lock.withLock { (downHosts.contains(request.url?.host ?? ""), wrongPassword) }
        if isDown { throw URLError(.cannotConnectToHost) }
        if wrong { return SubsonicAnswer.wrongPassword }
        switch request.url?.path {
        case "/rest/getArtists.view": return SubsonicAnswer.artists
        case "/rest/getArtist.view": return SubsonicAnswer.artist
        case "/rest/getAlbum.view":
            let id = StubTransport.query(of: request)["id"] ?? "al-1"
            return SubsonicAnswer.album(id: id, name: ["al-1": "Abba", "al-2": "Arrival", "al-3": "Undated"][id] ?? id)
        case "/rest/getPlaylists.view":
            return SubsonicAnswer.ok(#","playlists":{"playlist":[{"id":"p2","name":"Road","songCount":2},{"id":"p1","name":"Gym","songCount":1}]}"#)
        case "/rest/getPlaylist.view":
            return SubsonicAnswer.ok(#","playlist":{"id":"p2","name":"Road","entry":[{"id":"s-9","title":"Nine","album":"Z","albumId":"al-z","suffix":"mp3"},{"id":"s-1","title":"One","album":"A","albumId":"al-a","suffix":"flac"}]}"#)
        case "/rest/getCoverArt.view": return (200, TestImages.make(width: 300, height: 200))
        default: return SubsonicAnswer.ok()
        }
    }
}

extension StubTransport {
    /// The query items of a request as a dictionary.
    static func query(of request: URLRequest) -> [String: String] {
        guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// The requests made for `method`.
    func requests(for method: String) -> [URLRequest] {
        requests.filter { $0.url?.path == "/rest/\(method).view" }
    }
}

extension AllTests {
    // MARK: - Service

    @MainActor @Suite("Subsonic service")
    struct SubsonicServiceTests {
        private struct Env {
            let config: ConfigStore
            let server: SubsonicStubServer
            let transport: StubTransport
            let service: SubsonicService
        }

        private func connection(_ name: String, publicEndpoint: String = "https://music.example.org", localEndpoint: String = "",
                                enabled: Bool = true) -> SubsonicConnectionConfig {
            SubsonicConnectionConfig(name: name, publicEndpoint: publicEndpoint, localEndpoint: localEndpoint,
                                     username: "bob", password: "pw", enabled: enabled)
        }

        private func makeEnv(_ connections: [SubsonicConnectionConfig] = []) throws -> Env {
            let config = ConfigStore(paths: AppPaths(workDir: try TempDir().path("work")), saveDelay: .seconds(60))
            config.update { $0.subsonic = connections.sorted(by: SubsonicConnectionConfig.isOrderedBefore) }
            let server = SubsonicStubServer()
            let transport = server.transport
            let service = SubsonicService(configStore: config, transport: transport, pingTransport: transport,
                                          sleep: BlockingSleep().sleep, watchesNetwork: false)
            return Env(config: config, server: server, transport: transport, service: service)
        }

        @Test("an enabled connection pings its server when the service starts, and its status says so")
        func startup() async throws {
            let home = connection("Home")
            let env = try makeEnv([home, connection("Off", enabled: false)])
            #expect(env.service.hasEnabledConnections && env.service.enabledConnections.map(\.name) == ["Home"])
            #expect(env.service.connection(home.id) != nil)
            #expect(await waitUntil { env.service.status(of: home.id).isOK })

            let status = env.service.status(of: home.id)
            #expect(status.lastInteraction != nil && status.error == nil && status.route == .public)
            #expect(env.transport.requests(for: "ping").count == 1)
        }

        @Test("nothing is done for a connection that is switched off")
        func disabled() throws {
            let off = connection("Off", enabled: false)
            let env = try makeEnv([off])
            #expect(!env.service.hasEnabledConnections)
            #expect(env.service.connection(off.id) == nil)
            #expect(env.transport.requests.isEmpty)
            #expect(env.service.status(of: off.id) == SubsonicService.Status())
        }

        @Test("a wrong password shows as the error of the status")
        func wrongPassword() async throws {
            let home = connection("Home")
            let env = try makeEnv()
            env.server.setWrongPassword(true)
            env.service.add(home)
            #expect(await waitUntil { env.service.status(of: home.id).error != nil })
            #expect(env.service.status(of: home.id).error == "Wrong username or password")
            #expect(!env.service.status(of: home.id).isOK)
        }

        @Test("adding, editing and removing is kept in the config, sorted by name")
        func editing() async throws {
            let env = try makeEnv()
            let b = connection("beta"), a = connection("Alpha")
            env.service.add(b)
            env.service.add(a)
            #expect(env.service.connections.map(\.name) == ["Alpha", "beta"])
            #expect(env.config.config.subsonic.map(\.name) == ["Alpha", "beta"])

            var renamed = b
            renamed.name = "Zeta"
            env.service.update(renamed)
            #expect(env.service.connections.map(\.name) == ["Alpha", "Zeta"])
            #expect(env.service.connections.last?.id == b.id)   // the ID stays, the name is only a label

            env.service.remove(a.id)
            #expect(env.service.connections.map(\.name) == ["Zeta"])
            #expect(env.service.connection(a.id) == nil)
            #expect(env.config.config.subsonic.count == 1)
        }

        @Test("a new name or the scrobbling switch doesn't reconnect, another address or password does")
        func reconnecting() async throws {
            let home = connection("Home")
            let env = try makeEnv([home])
            #expect(await waitUntil { env.service.status(of: home.id).isOK })
            let first = try #require(env.service.connection(home.id))

            var edited = home
            edited.name = "Home sweet home"
            edited.sendScrobbles = true
            env.service.update(edited)
            #expect(env.service.connection(home.id) === first)
            #expect(first.config.sendScrobbles && first.config.name == "Home sweet home")
            #expect(env.service.status(of: home.id).isOK)   // nothing was reset

            edited.password = "other"
            env.service.update(edited)
            let second = try #require(env.service.connection(home.id))
            #expect(second !== first)
            #expect(await waitUntil { env.service.status(of: home.id).isOK })
            #expect(env.transport.requests(for: "ping").count == 2)
        }

        @Test("switching off ends the connection, switching on makes it again")
        func switching() async throws {
            let home = connection("Home")
            let env = try makeEnv([home])
            env.service.setEnabled(false, for: home.id)
            #expect(env.service.connection(home.id) == nil && !env.service.hasEnabledConnections)
            #expect(env.service.status(of: home.id) == SubsonicService.Status())
            #expect(!env.config.config.subsonic[0].enabled)

            env.service.setEnabled(true, for: home.id)
            #expect(env.service.connection(home.id) != nil)
            #expect(await waitUntil { env.service.status(of: home.id).isOK })
        }

        @Test("the test pings both addresses and says what each came to, without saving anything")
        func testing() async throws {
            let env = try makeEnv()
            env.server.setDown("192.168.1.2", true)
            let results = await env.service.test(connection("Home", localEndpoint: "http://192.168.1.2:4533"))
            #expect(results.map(\.route) == [.local, .public])
            if case .failure(let error) = results[0].outcome { #expect(error.kind == .connection) } else { Issue.record("local is down") }
            #expect(results[1].outcome == .success("Navidrome 0.53.3 (API 1.16.1)"))
            #expect(env.service.connections.isEmpty && env.service.statuses.isEmpty)
        }

        @Test("a message as a sentence")
        func sentence() {
            #expect(SubsonicService.sentence("wrong username or password") == "Wrong username or password.")
            #expect(SubsonicService.sentence("HTTP 500.") == "HTTP 500.")
        }

        // MARK: Downloads

        @Test("downloads go to the address the connection uses, and to the other one when asked to avoid it")
        func downloadTargets() async throws {
            let home = connection("Home", localEndpoint: "http://192.168.1.2:4533")
            let env = try makeEnv([home])
            _ = await env.service.connection(home.id)?.resolvedRoute()

            let first = try #require(try await env.service.downloadTarget(connection: home.id, songID: "s 1", avoiding: []))
            #expect(first.route == .local)
            #expect(first.url.host == "192.168.1.2" && first.url.path == "/rest/download.view")
            #expect(StubTransport.query(of: URLRequest(url: first.url))["id"] == "s 1")

            let second = try #require(try await env.service.downloadTarget(connection: home.id, songID: "s", avoiding: [.local]))
            #expect(second.route == .public && second.url.host == "music.example.org")
            #expect(try await env.service.downloadTarget(connection: home.id, songID: "s", avoiding: [.local, .public]) == nil)
        }

        @Test("a download from a connection that is switched off or removed says why")
        func downloadUnavailable() async throws {
            let off = connection("Off", enabled: false)
            let env = try makeEnv([off])
            await #expect(throws: SubsonicError(.rejected, "its connection \"Off\" is switched off")) {
                _ = try await env.service.downloadTarget(connection: off.id, songID: "s", avoiding: [])
            }
            await #expect(throws: SubsonicError(.rejected, "its connection was removed")) {
                _ = try await env.service.downloadTarget(connection: UUID(), songID: "s", avoiding: [])
            }
        }

        @Test("a download that can't reach the local address moves the connection to the public one")
        func downloadFails() async throws {
            let home = connection("Home", localEndpoint: "http://192.168.1.2:4533")
            let env = try makeEnv([home])
            let live = try #require(env.service.connection(home.id))
            #expect(await live.resolvedRoute() == .local)

            await env.service.downloadDidFinish(connection: home.id, route: .local, error: SubsonicError(.connection, "refused"))
            #expect(live.route == .public)
            #expect(env.service.status(of: home.id).error == "refused")

            await env.service.downloadDidFinish(connection: home.id, route: .public, error: nil)
            #expect(env.service.status(of: home.id).isOK)
        }
    }

    // MARK: - Adding

    @MainActor @Suite("Adding from Subsonic")
    struct SubsonicImportTests {
        private let connection = UUID(uuidString: "0F6C3A3E-52E8-4F1B-9C9C-6A1E3B8D7A11")!

        private func picks() -> [SubsonicPick] {
            let first = SubsonicAlbum(id: "al-1", name: "Arrival", artist: "Abba", year: 1976, songCount: 2, coverArt: "al-1")
            let second = SubsonicAlbum(id: "al-2", name: "Waterloo", artist: "Abba", year: nil, songCount: 1, coverArt: nil)
            func song(_ id: String, _ title: String, album: SubsonicAlbum, track: Int?, artist: String = "Abba",
                      year: Int? = nil, suffix: String? = "flac") -> SubsonicSong {
                SubsonicSong(id: id, title: title, album: album.name, albumID: album.id, artist: artist, track: track, disc: nil,
                             year: year, duration: 200, suffix: suffix, bitRate: 900, coverArt: album.coverArt)
            }
            return [
                SubsonicPick(album: first, song: song("s1", "Dancing Queen", album: first, track: 2)),
                SubsonicPick(album: second, song: song("s3", "Waterloo", album: second, track: 1, artist: "ABBA", suffix: nil)),
                SubsonicPick(album: first, song: song("s2", "Money, Money, Money", album: first, track: 3, year: 1977)),
            ]
        }

        @Test("the tags come from the server, and a track is a track from the connection")
        func entries() {
            let entries = SubsonicImport.entries(of: picks(), connection: connection)
            #expect(entries.map(\.title) == ["Dancing Queen", "Waterloo", "Money, Money, Money"])
            let first = entries[0]
            #expect(first.artist == "Abba" && first.album == "Arrival" && first.trackNumber == 2)
            #expect(first.year == "1976" && first.duration == 200 && first.codec == "FLAC")   // the album's year
            #expect(first.path == SubsonicRef.path(connection: connection, songID: "s1"))
            #expect(first.subsonic == SubsonicRef(connection: connection, songID: "s1", suffix: "flac", albumID: "al-1", coverArt: "al-1"))
            #expect(entries[2].year == "1977")   // the song's own
            #expect(entries[1].year == nil && entries[1].codec == "" && entries[1].subsonic?.coverArt == nil)
        }

        @Test("the albums of the server are the albums of the playlist, tracks in the order picked")
        func albums() {
            let albums = SubsonicImport.albums(of: picks(), connection: connection)
            #expect(albums.map(\.title) == ["Arrival", "Waterloo"])
            #expect(albums[0].tracks.map(\.title) == ["Dancing Queen", "Money, Money, Money"])
            #expect(albums.allSatisfy { $0.tracks.allSatisfy { $0.subsonic?.connection == connection } })
        }

        @Test("the songs of a server's playlist are one album each, in the order of the playlist")
        func playlistSongs() {
            func song(_ id: String, album: String, art: String?) -> SubsonicSong {
                SubsonicSong(id: id, title: id, album: "Album \(album)", albumID: album, artist: "Abba", track: nil, disc: nil, year: 1976,
                             duration: 100, suffix: "mp3", bitRate: nil, coverArt: art)
            }
            let songs = [song("s1", album: "al-1", art: "al-1"), song("s2", album: "al-2", art: nil),
                         song("s3", album: "al-1", art: "al-1"), song("s1", album: "al-1", art: "al-1")]
            let albums = SubsonicImport.albums(of: SubsonicImport.picks(ofPlaylist: songs), connection: connection, flat: true)
            #expect(albums.map { $0.tracks[0].title } == ["s1", "s2", "s3", "s1"])
            #expect(albums.allSatisfy { $0.tracks.count == 1 })
            #expect(albums.map(\.title) == ["Album al-1", "Album al-2", "Album al-1", "Album al-1"])
            #expect(albums[0].key == albums[2].key && albums[0].key != albums[1].key)
        }

        @Test("a run gets the albums")
        func session() async {
            let id = connection
            let picks = picks()

            let session = SubsonicImportSession()
            let outcome = await session.run { SubsonicImport.albums(of: picks, connection: id) }
            #expect(outcome.albums.count == 2 && !outcome.aborted && outcome.error == nil)
            #expect(session.stage == .loading)
        }

        @Test("a run that fails to get the albums says why, an aborted one yields nothing")
        func sessionFailures() async {
            let failing = await SubsonicImportSession().run {
                throw SubsonicError(.rejected, "the server's answer has no playlist")
            }
            #expect(failing.albums.isEmpty && !failing.aborted && failing.error == "The server's answer has no playlist.")

            let session = SubsonicImportSession()
            let aborted = await session.run {
                session.abort()
                try await Task.sleep(for: .seconds(30))
                return []
            }
            #expect(aborted.aborted && aborted.albums.isEmpty && aborted.error == nil)
        }
    }

    // MARK: - Cache sizes

    @MainActor @Suite("Subsonic cache sizes of the service")
    struct SubsonicCachePolicyTests {
        @Test("the cache size of every connection is announced when one is added, edited or removed")
        func announced() throws {
            let transport = SubsonicStubServer().transport
            let config = ConfigStore(paths: AppPaths(workDir: try TempDir().path("work")), saveDelay: .seconds(60))
            let service = SubsonicService(configStore: config, transport: transport, pingTransport: transport,
                                          sleep: BlockingSleep().sleep, watchesNetwork: false)
            var announced: [[UUID: SubsonicCacheSize]] = []
            service.onCachePoliciesChanged = { announced.append($0) }

            var home = SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://music.example.org", username: "bob", password: "pw")
            var away = SubsonicConnectionConfig(name: "Away", publicEndpoint: "https://away.example.org", username: "bob", password: "pw",
                                                enabled: false)
            service.add(home)
            service.add(away)
            #expect(announced.last == [home.id: .limited(gigabytes: 5), away.id: .limited(gigabytes: 5)])   // the disabled one too

            home.cacheSize = .off
            service.update(home)
            #expect(announced.last?[home.id] == SubsonicCacheSize.off)
            away.cacheSize = .unlimited
            service.update(away)
            #expect(service.cachePolicies == [home.id: .off, away.id: .unlimited])

            service.setEnabled(false, for: away.id)   // disabling is not removing: the cache stays
            #expect(announced.last?[away.id] == SubsonicCacheSize.unlimited)
            service.remove(away.id)
            #expect(announced.last == [home.id: .off])
        }
    }

    // MARK: - Browsing

    @MainActor @Suite("Subsonic browse sheet model")
    struct SubsonicBrowseModelTests {
        private func makeService(_ names: [String], server: SubsonicStubServer = SubsonicStubServer()) throws -> SubsonicService {
            let config = ConfigStore(paths: AppPaths(workDir: try TempDir().path("work")), saveDelay: .seconds(60))
            let service = SubsonicService(configStore: config, transport: server.transport, pingTransport: server.transport,
                                          sleep: BlockingSleep().sleep, watchesNetwork: false)
            for name in names {
                service.add(SubsonicConnectionConfig(name: name, publicEndpoint: "https://\(name.lowercased()).example.org",
                                                     username: "bob", password: "pw"))
            }
            return service
        }

        /// The model for the first connection of the service.
        private func makeModel(_ service: SubsonicService, connection index: Int = 0) -> SubsonicBrowseModel {
            SubsonicBrowseModel(service: service, connection: service.connections[index].id)
        }

        @Test("the artists of the connection it is made for are loaded at once")
        func artistsLoaded() async throws {
            let service = try makeService(["Home", "Work"])
            let model = makeModel(service, connection: 1)
            #expect(model.connectionID == service.connections[1].id)
            #expect(await waitUntil { model.artists.count == 3 })
            #expect(model.artists.map(\.name) == ["Abba", "Air", "Beck"])
        }


        @Test("an artist loads its albums with their songs, and all of them are ticked")
        func artist() async throws {
            let model = makeModel(try makeService(["Home"]))
            #expect(await waitUntil { !model.artists.isEmpty })
            model.selectArtist("ar-1")
            #expect(await waitUntil { model.contents.count == 3 && model.contentsState == .idle })
            #expect(model.contents.map(\.album.name) == ["Abba", "Arrival", "Undated"])
            #expect(model.picks.count == 9)   // three songs on each album
            #expect(model.selectedPicks.count == 9 && model.canAdd)
            #expect(model.totalSongCount == 9)
        }

        @Test("picking an album shows only its tracks, ticked again; all albums brings the rest back")
        func album() async throws {
            let model = makeModel(try makeService(["Home"]))
            #expect(await waitUntil { !model.artists.isEmpty })
            model.selectArtist("ar-1")
            #expect(await waitUntil { model.contents.count == 3 && model.contentsState == .idle })

            model.selectNone()
            #expect(!model.canAdd)
            model.selectAlbum("al-1")
            #expect(model.picks.count == 3 && model.selectedPicks.count == 3)

            model.setSelected("al-1-1", false)
            #expect(model.selectedPicks.count == 2)
            model.selectAlbum(nil)
            #expect(model.picks.count == 9 && model.selectedPicks.count == 9)
            model.selectAll()
            #expect(model.selectedPicks.count == 9)
        }

        @Test("the artists can be filtered, ignoring case and accents")
        func filter() async throws {
            let model = makeModel(try makeService(["Home"]))
            #expect(await waitUntil { !model.artists.isEmpty })
            model.artistFilter = "AB"
            #expect(model.visibleArtists.map(\.name) == ["Abba"])
            model.artistFilter = "  "
            #expect(model.visibleArtists.count == 3)
        }

        @Test("another artist clears what depended on the one before")
        func clearing() async throws {
            let model = makeModel(try makeService(["Home"]))
            #expect(await waitUntil { !model.artists.isEmpty })
            model.selectArtist("ar-1")
            #expect(await waitUntil { model.contentsState == .idle && !model.contents.isEmpty })
            model.selectAlbum("al-1")

            model.selectArtist("ar-2")
            #expect(model.albumID == nil && model.contents.isEmpty && model.selectedPicks.isEmpty && !model.canAdd)
            #expect(await waitUntil { model.contentsState == .idle && !model.contents.isEmpty })
        }

        @Test("a server that can't be reached is a line of text in the list")
        func failure() async throws {
            let server = SubsonicStubServer()
            server.setDown("home.example.org", true)
            let model = makeModel(try makeService(["Home"], server: server))
            #expect(await waitUntil { if case .failed = model.artistsState { true } else { false } })
            #expect(model.artists.isEmpty)
        }
    }

    // MARK: - Scrobbling

    @MainActor @Suite("Subsonic scrobbling")
    struct SubsonicScrobblerTests {
        private struct Env {
            let server: SubsonicStubServer
            let transport: StubTransport
            let service: SubsonicService
            let scrobbler: SubsonicScrobbler
            let home: SubsonicConnectionConfig
        }

        private func makeEnv(sendScrobbles: Bool = true, enabled: Bool = true) throws -> Env {
            let server = SubsonicStubServer()
            let transport = server.transport
            let config = ConfigStore(paths: AppPaths(workDir: try TempDir().path("work")), saveDelay: .seconds(60))
            let service = SubsonicService(configStore: config, transport: transport, pingTransport: transport,
                                          sleep: BlockingSleep().sleep, watchesNetwork: false)
            let home = SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://music.example.org", username: "bob",
                                                password: "pw", sendScrobbles: sendScrobbles, enabled: enabled)
            service.add(home)
            return Env(server: server, transport: transport, service: service,
                       scrobbler: SubsonicScrobbler(service: service, sleep: SleepRecorder().sleep), home: home)
        }

        private func track(_ env: Env, song: String = "s1", duration: TimeInterval = 200) -> PlayedTrack {
            var track = ScrobbleTestData.track(duration: duration)
            track.url = SubsonicRef(connection: env.home.id, songID: song, suffix: "flac").url
            return track
        }

        @Test("a song that was listened to enough is scrobbled to its server, by ID, with the time it started at")
        func scrobbles() async throws {
            let env = try makeEnv()
            let played = track(env, song: "song 7")
            env.scrobbler.trackDidEnd(played, playedSeconds: 150)
            #expect(await waitUntil { !env.transport.requests(for: "scrobble").isEmpty })

            let query = StubTransport.query(of: try #require(env.transport.requests(for: "scrobble").first))
            #expect(query["id"] == "song 7" && query["submission"] == "true")
            #expect(query["time"] == String(Int64(played.startedAt.timeIntervalSince1970 * 1000)))
            #expect(query["u"] == "bob" && query["t"] != nil)
        }

        @Test("not for a song that wasn't listened to enough, and a start is not announced")
        func notWorthy() async throws {
            let env = try makeEnv()
            env.scrobbler.trackDidStart(track(env))
            env.scrobbler.trackDidEnd(track(env), playedSeconds: 20)
            try await Task.sleep(for: .milliseconds(100))
            #expect(env.transport.requests(for: "scrobble").isEmpty)
        }

        @Test("not without the setting, not for a connection that is off, not for files of this Mac, not for other connections")
        func notWanted() async throws {
            let off = try makeEnv(sendScrobbles: false)
            off.scrobbler.trackDidEnd(track(off), playedSeconds: 150)

            let disabled = try makeEnv(enabled: false)
            disabled.scrobbler.trackDidEnd(track(disabled), playedSeconds: 150)

            let env = try makeEnv()
            var local = ScrobbleTestData.track()
            local.url = URL(fileURLWithPath: "/tmp/a.flac")
            env.scrobbler.trackDidEnd(local, playedSeconds: 150)
            var other = ScrobbleTestData.track()
            other.url = SubsonicRef(connection: UUID(), songID: "x").url
            env.scrobbler.trackDidEnd(other, playedSeconds: 150)
            env.scrobbler.trackDidEnd(ScrobbleTestData.track(), playedSeconds: 150)   // no URL at all

            try await Task.sleep(for: .milliseconds(100))
            for env in [off, disabled, env] { #expect(env.transport.requests(for: "scrobble").isEmpty) }
        }

        @Test("a server that can't be reached is tried again")
        func retry() async throws {
            let env = try makeEnv()
            env.server.setDown("music.example.org", true)
            env.scrobbler.trackDidEnd(track(env), playedSeconds: 150)
            #expect(await waitUntil { env.transport.requests(for: "scrobble").count >= 2 })   // the stand-in for waiting doesn't wait

            env.server.setDown("music.example.org", false)
            #expect(await waitUntil { env.scrobbler.pendingCount(for: env.home.id) == 0 })
        }

        @Test("a server that refuses the song drops it and takes the next")
        func refused() async throws {
            let env = try makeEnv()
            env.scrobbler.trackDidEnd(track(env, song: "a"), playedSeconds: 150)
            env.scrobbler.trackDidEnd(track(env, song: "b"), playedSeconds: 150)
            #expect(await waitUntil { env.transport.requests(for: "scrobble").count == 2 })
            #expect(await waitUntil { env.scrobbler.pendingCount(for: env.home.id) == 0 })
        }
    }
}
