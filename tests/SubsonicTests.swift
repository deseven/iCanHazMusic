// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

/// Answers a Subsonic server gives.
enum SubsonicAnswer {
    static func ok(_ extra: String = "") -> StubTransport.Answer {
        let body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.53.3"\#(extra)}}"#
        return (200, Data(body.utf8))
    }

    static func failed(code: Int, message: String) -> StubTransport.Answer {
        let body = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":\#(code),"message":"\#(message)"}}}"#
        return (200, Data(body.utf8))
    }

    static let wrongPassword = failed(code: 40, message: "Wrong username or password")

    static let artists = ok(#","artists":{"ignoredArticles":"The","index":[{"name":"A","artist":[{"id":"ar-1","name":"Abba","albumCount":2},{"id":"ar-2","name":"Air","albumCount":1}]},{"name":"B","artist":[{"id":7,"name":"Beck","albumCount":"3"}]}]}"#)

    static let artist = ok(#","artist":{"id":"ar-1","name":"Abba","album":[{"id":"al-2","name":"Arrival","year":1976,"songCount":2,"coverArt":"al-2"},{"id":"al-1","name":"Abba","year":1975,"songCount":1},{"id":"al-3","name":"Undated"}]}"#)

    /// An album with three songs whose IDs are made from the album's (so that albums don't share songs).
    static func album(id: String, name: String) -> StubTransport.Answer {
        ok(#","album":{"id":"\#(id)","name":"\#(name)","artist":"Abba","year":1976,"coverArt":"\#(id)","song":[{"id":"\#(id)-1","title":"One","track":1,"duration":100,"suffix":"mp3"},{"id":"\#(id)-2","title":"Two","track":2,"duration":100,"suffix":"mp3"},{"id":"\#(id)-3","title":"Three","track":3,"duration":100,"suffix":"mp3"}]}"#)
    }

    static let album = ok(#","album":{"id":"al-1","name":"Arrival","artist":"Abba","year":1976,"coverArt":"al-1","song":[{"id":"s-3","title":"Three","track":1,"discNumber":2,"duration":181,"suffix":"FLAC","bitRate":900},{"id":"s-2","title":"Two","track":2,"discNumber":1,"duration":200,"suffix":"mp3"},{"id":"s-1","title":"One","track":1,"discNumber":1,"duration":"150","suffix":"mp3","artist":"Abba and friends"}]}"#)
}

extension AllTests {
    // MARK: - Config

    @MainActor @Suite("Subsonic connection settings")
    struct SubsonicConfigTests {
        private func valid() -> SubsonicConnectionConfig {
            SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://music.example.org", username: "bob", password: "pw")
        }

        @Test("an endpoint is normalized: scheme, host, no trailing slash, no /rest")
        func endpoints() {
            #expect(SubsonicConnectionConfig.normalizedEndpoint(" HTTP://Music.Example.org:4533/ ") == "http://music.example.org:4533")
            #expect(SubsonicConnectionConfig.normalizedEndpoint("https://example.org/navidrome/rest/") == "https://example.org/navidrome")
            #expect(SubsonicConnectionConfig.normalizedEndpoint("https://example.org/rest") == "https://example.org")
            #expect(SubsonicConnectionConfig.normalizedEndpoint("") == nil)
            #expect(SubsonicConnectionConfig.normalizedEndpoint("ftp://example.org") == nil)
            #expect(SubsonicConnectionConfig.normalizedEndpoint("example.org") == nil)
        }

        @Test("one of the two endpoints is enough, and local goes first")
        func routes() {
            var config = valid()
            #expect(config.routes == [.public])
            config.localEndpoint = "http://192.168.1.2:4533"
            #expect(config.routes == [.local, .public])
            config.publicEndpoint = ""
            #expect(config.routes == [.local])
            #expect(config.problem(among: []) == nil)
            config.localEndpoint = ""
            #expect(config.problem(among: []) != nil)
        }

        @Test("what can't be saved: name, endpoints, user, password")
        func problems() {
            #expect(valid().problem(among: []) == nil)

            var config = valid()
            config.name = "  "
            #expect(config.problem(among: []) != nil)

            config = valid()
            config.localEndpoint = "not a url"
            #expect(config.problem(among: []) != nil)   // a filled in endpoint has to be right, too

            config = valid()
            config.username = ""
            #expect(config.problem(among: []) != nil)

            config = valid()
            config.password = ""
            #expect(config.problem(among: []) != nil)

            let mine = valid()
            var other = valid()
            other.name = "HOME"
            #expect(mine.problem(among: [other]) != nil)   // names differ in more than case
            other.id = mine.id
            #expect(mine.problem(among: [other]) == nil)   // itself doesn't count
        }

        @Test("the password is obfuscated in the file and comes back; a new connection doesn't send scrobbles")
        func coding() throws {
            let config = SubsonicConnectionConfig(name: "Home", publicEndpoint: "https://x.org", username: "bob", password: "hunter2")
            #expect(!config.sendScrobbles)
            let data = try JSONEncoder().encode(config)
            #expect(!String(decoding: data, as: UTF8.self).contains("hunter2"))
            #expect(try JSONDecoder().decode(SubsonicConnectionConfig.self, from: data) == config)
        }

        @Test("the cache size is 5 GB to begin with, is kept as 0 (none), -1 (unlimited) or GB, and a number that means nothing is the default")
        func cacheSize() throws {
            #expect(valid().cacheSize == .limited(gigabytes: 5))
            for size in [SubsonicCacheSize.off, .unlimited, .limited(gigabytes: 1), .limited(gigabytes: 100)] {
                var config = valid()
                config.cacheSize = size
                let data = try JSONEncoder().encode(config)
                #expect(try JSONDecoder().decode(SubsonicConnectionConfig.self, from: data).cacheSize == size)
            }
            func decoded(_ json: String) throws -> SubsonicCacheSize {
                try JSONDecoder().decode(SubsonicConnectionConfig.self, from: Data(json.utf8)).cacheSize
            }
            #expect(try decoded(#"{"cache_size": 0}"#) == .off)
            #expect(try decoded(#"{"cache_size": -1}"#) == .unlimited)
            #expect(try decoded(#"{"cache_size": 20}"#) == .limited(gigabytes: 20))
            #expect(try decoded(#"{"cache_size": 101}"#) == .default)
            #expect(try decoded(#"{"cache_size": -7}"#) == .default)
            #expect(try decoded(#"{"cache_size": "big"}"#) == .default)
            #expect(try decoded("{}") == .default)
            #expect(SubsonicCacheSize.off.title == "None" && SubsonicCacheSize.unlimited.title == "Unlimited")
            #expect(SubsonicCacheSize.limited(gigabytes: 5).title == "5 GB")
        }

        @Test("decoding is forgiving")
        func lenient() throws {
            let config = try JSONDecoder().decode(SubsonicConnectionConfig.self, from: Data(#"{"name": 5, "enabled": "yes"}"#.utf8))
            #expect(config.name == "" && config.enabled && !config.sendScrobbles && config.routes.isEmpty)
        }

        @Test("in the config file: kept sorted, unreadable ones left out, a repeated ID replaced")
        func appConfig() throws {
            let id = UUID()
            let json = """
            {"subsonic": [
              {"id": "\(id)", "name": "b", "public_endpoint": "https://b.org/", "username": "u", "password": ""},
              {"id": "\(id)", "name": "a", "local_endpoint": "http://a.local", "username": "u", "password": ""},
              "garbage"
            ]}
            """
            let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)).validated()
            #expect(decoded.subsonic.map(\.name) == ["a", "b"])
            #expect(Set(decoded.subsonic.map(\.id)).count == 2)
            #expect(decoded.subsonic[1].publicEndpoint == "https://b.org")
        }
    }

    // MARK: - API

    @MainActor @Suite("Subsonic API")
    struct SubsonicAPITests {
        @Test("the token is the one of the API description")
        func token() {
            #expect(SubsonicAPI.token(password: "sesame", salt: "c19b2d") == "26719a1196d2a940705a59634eb18eab")
        }

        @Test("a URL has the credentials as the token and a salt, never the password")
        func url() throws {
            let url = try #require(SubsonicAPI.url(endpoint: "https://x.org/navidrome", method: "getAlbum", username: "bo b",
                                                   password: "sesame", params: [("id", "a&b")], salt: "c19b2d"))
            let text = url.absoluteString
            #expect(text.hasPrefix("https://x.org/navidrome/rest/getAlbum.view?"))
            #expect(text.contains("u=bo%20b") && text.contains("s=c19b2d") && text.contains("t=26719a1196d2a940705a59634eb18eab"))
            #expect(text.contains("v=1.16.1") && text.contains("f=json") && text.contains("id=a%26b"))
            #expect(!text.contains("sesame"))
            #expect(SubsonicAPI.redacted(url) == "https://x.org/navidrome/rest/getAlbum.view")
        }

        @Test("every request has its own salt")
        func salts() {
            #expect(SubsonicAPI.makeSalt() != SubsonicAPI.makeSalt())
            #expect(SubsonicAPI.makeSalt().count == 16)
        }

        @Test("answers: ok, errors by code, and what isn't Subsonic at all")
        func parse() throws {
            let ok = SubsonicAnswer.ok()
            let response = try SubsonicAPI.parse(status: ok.status, body: ok.body)
            #expect(SubsonicAPI.serverInfo(response) == "Navidrome 0.53.3 (API 1.16.1)")

            func error(_ answer: StubTransport.Answer) -> SubsonicError? {
                do { _ = try SubsonicAPI.parse(status: answer.status, body: answer.body) } catch { return error as? SubsonicError }
                return nil
            }
            let wrong = error(SubsonicAnswer.wrongPassword)
            #expect(wrong?.kind == .authentication && wrong?.message == "Wrong username or password")
            #expect(error(SubsonicAnswer.failed(code: 70, message: "gone"))?.kind == .notFound)
            #expect(error(SubsonicAnswer.failed(code: 0, message: "?"))?.kind == .rejected)
            #expect(error((200, Data("<html></html>".utf8)))?.kind == .connection)
            #expect(error((502, Data("<html></html>".utf8)))?.kind == .connection)
            #expect(error((401, Data()))?.kind == .authentication)
        }

        @Test("artists: the ones of every index, IDs and counts as strings or numbers")
        func artists() throws {
            let answer = SubsonicAnswer.artists
            let artists = SubsonicAPI.parseArtists(try SubsonicAPI.parse(status: answer.status, body: answer.body))
            #expect(artists.map(\.name) == ["Abba", "Air", "Beck"])
            #expect(artists[2].id == "7" && artists[2].albumCount == 3)
        }

        @Test("an artist's albums, an album's songs")
        func albumsAndSongs() throws {
            let artistAnswer = SubsonicAnswer.artist
            let artist = try #require(SubsonicAPI.parseArtist(try SubsonicAPI.parse(status: 200, body: artistAnswer.body)))
            #expect(artist.artist.name == "Abba" && artist.albums.count == 3)
            #expect(artist.albums[0].artist == "Abba")   // the artist's name when the album doesn't say

            let albumAnswer = SubsonicAnswer.album
            let album = try #require(SubsonicAPI.parseAlbum(try SubsonicAPI.parse(status: 200, body: albumAnswer.body)))
            #expect(album.album.name == "Arrival" && album.album.year == 1976)
            let songs = album.songs.sorted(by: SubsonicSong.isOrderedBefore)
            #expect(songs.map(\.title) == ["One", "Two", "Three"])   // disc 1 first
            #expect(songs[0].artist == "Abba and friends" && songs[0].duration == 150)
            #expect(songs[1].artist == "" && songs[1].album == "Arrival" && songs[1].year == 1976)
            #expect(songs[2].suffix == "flac" && songs[2].coverArt == "al-1")
        }

        @Test("the playlists of a server, and the songs of one in its order (a song can be there twice)")
        func playlists() throws {
            let list = SubsonicAnswer.ok(#","playlists":{"playlist":[{"id":"p1","name":"Road","songCount":2,"duration":400},{"id":7,"name":"Gym"}]}"#)
            let playlists = SubsonicAPI.parsePlaylists(try SubsonicAPI.parse(status: 200, body: list.body))
            #expect(playlists.map(\.id) == ["p1", "7"])
            #expect(playlists[0].name == "Road" && playlists[0].songCount == 2 && playlists[0].duration == 400)
            #expect(playlists[1].songCount == nil)

            // No playlists at all: the server leaves `playlist` out.
            let none = SubsonicAnswer.ok(#","playlists":{}"#)
            #expect(SubsonicAPI.parsePlaylists(try SubsonicAPI.parse(status: 200, body: none.body)).isEmpty)

            let entries = SubsonicAnswer.ok(#","playlist":{"id":"p1","name":"Road","entry":[{"id":"s-2","title":"Two","album":"B","albumId":"al-b","suffix":"MP3"},{"id":"s-1","title":"One","album":"A","albumId":"al-a","coverArt":"c-1"},{"id":"s-2","title":"Two"},{"id":"d-1","isDir":true}]}"#)
            let songs = try #require(SubsonicAPI.parsePlaylistEntries(try SubsonicAPI.parse(status: 200, body: entries.body)))
            #expect(songs.map(\.id) == ["s-2", "s-1", "s-2"])
            #expect(songs[0].albumID == "al-b" && songs[0].suffix == "mp3" && songs[1].coverArt == "c-1")

            let empty = SubsonicAnswer.ok(#","playlist":{"id":"p2","name":"Empty"}"#)
            #expect(try #require(SubsonicAPI.parsePlaylistEntries(try SubsonicAPI.parse(status: 200, body: empty.body))).isEmpty)
            #expect(SubsonicAPI.parsePlaylistEntries(try SubsonicAPI.parse(status: 200, body: SubsonicAnswer.ok().body)) == nil)
        }
    }

    // MARK: - Connection

    @MainActor @Suite("Subsonic connection")
    struct SubsonicConnectionTests {
        private static let localHost = "192.168.1.2"
        private static let publicHost = "music.example.org"

        /// The servers behind the two addresses: what `up` says is answered with `answer`, the rest can't be reached.
        private final class Network: @unchecked Sendable {
            private let lock = NSLock()
            private var reachable: Set<String>
            private var wrongPassword = false

            init(up: Set<String>) { reachable = up }

            func set(_ host: String, up: Bool) {
                lock.withLock { if up { reachable.insert(host) } else { reachable.remove(host) } }
            }

            func rejectPassword(_ value: Bool) { lock.withLock { wrongPassword = value } }

            func answer(_ request: URLRequest) throws -> StubTransport.Answer {
                let host = request.url?.host ?? ""
                let (isUp, wrong) = lock.withLock { (reachable.contains(host), wrongPassword) }
                guard isUp else { throw URLError(.cannotConnectToHost) }
                if wrong { return SubsonicAnswer.wrongPassword }
                switch request.url?.path {
                case "/rest/getArtists.view": return SubsonicAnswer.artists
                case "/rest/getArtist.view": return SubsonicAnswer.artist
                case "/rest/getAlbum.view": return SubsonicAnswer.album
                case "/rest/getSong.view": return SubsonicAnswer.failed(code: 70, message: "Song not found")
                default: return SubsonicAnswer.ok()
                }
            }
        }

        private struct Env {
            let network: Network
            let transport: StubTransport
            let connection: SubsonicConnection
        }

        @MainActor
        private final class ActivityLog {
            var items: [SubsonicConnection.Activity] = []
        }

        private func makeEnv(local: Bool = true, public isPublic: Bool = true, up: Set<String>) -> (Env, ActivityLog) {
            let network = Network(up: up)
            let transport = StubTransport { request, _ in try network.answer(request) }
            let config = SubsonicConnectionConfig(
                name: "Home",
                publicEndpoint: isPublic ? "https://\(Self.publicHost)" : "",
                localEndpoint: local ? "http://\(Self.localHost):4533" : "",
                username: "bob", password: "pw")
            let connection = SubsonicConnection(config: config.normalized, transport: transport, pingTransport: transport,
                                                sleep: BlockingSleep().sleep)
            let log = ActivityLog()
            connection.onActivity = { log.items.append($0) }
            return (Env(network: network, transport: transport, connection: connection), log)
        }

        @Test("a single address is the address, and a ping is made to see that the server answers")
        func singleAddress() async {
            let (env, log) = makeEnv(local: false, up: [Self.publicHost])
            env.connection.start()
            #expect(await env.connection.resolvedRoute() == .public)
            #expect(await waitUntil { log.items.count == 1 })
            #expect(log.items.last?.error == nil && log.items.last?.route == .public)
            #expect(env.transport.requests.map { $0.url?.path } == ["/rest/ping.view"])
            env.connection.stop()
        }

        @Test("both addresses: the local one is used while it answers")
        func prefersLocal() async throws {
            let (env, log) = makeEnv(up: [Self.localHost, Self.publicHost])
            env.connection.start()
            #expect(await env.connection.resolvedRoute() == .local)
            let artists = try await env.connection.artists()
            #expect(artists.count == 3)
            #expect(env.transport.requests.allSatisfy { $0.url?.host == Self.localHost })
            #expect(log.items.last?.route == .local)
            env.connection.stop()
        }

        @Test("both addresses: without the local one, the public one is used, and the status says it works")
        func fallsBackToPublic() async throws {
            let (env, log) = makeEnv(up: [Self.publicHost])
            env.connection.start()
            #expect(await env.connection.resolvedRoute() == .public)
            _ = try await env.connection.artists()
            #expect(env.transport.requests.last?.url?.host == Self.publicHost)
            #expect(log.items.allSatisfy { $0.error == nil })
            env.connection.stop()
        }

        @Test("a call to an address that went away goes to the other one, and the connection stays with it")
        func switchesInFlight() async throws {
            let (env, _) = makeEnv(up: [Self.localHost, Self.publicHost])
            env.connection.start()
            #expect(await env.connection.resolvedRoute() == .local)

            env.network.set(Self.localHost, up: false)
            _ = try await env.connection.artists()
            #expect(env.connection.route == .public)
            #expect(env.transport.requests.suffix(2).map { $0.url?.host } == [Self.localHost, Self.publicHost])

            // The next one goes straight to the public address.
            let before = env.transport.requests.count
            _ = try await env.connection.artists()
            #expect(env.transport.requests.count == before + 1)
            env.connection.stop()
        }

        @Test("the probe takes the local address back when it is there again, and gives it up when it is gone")
        func probing() async {
            let (env, _) = makeEnv(up: [Self.publicHost])
            env.connection.start()
            #expect(await env.connection.resolvedRoute() == .public)

            env.network.set(Self.localHost, up: true)
            await env.connection.probe()
            #expect(env.connection.route == .local)

            env.network.set(Self.localHost, up: false)
            await env.connection.probe()
            #expect(env.connection.route == .public)
            env.connection.stop()
        }

        @Test("nothing reachable: the call fails as a connection problem and the status has the error")
        func unreachable() async {
            let (env, log) = makeEnv(up: [])
            env.connection.start()
            _ = await env.connection.resolvedRoute()
            do {
                _ = try await env.connection.artists()
                Issue.record("should have failed")
            } catch let error as SubsonicError {
                #expect(error.kind == .connection)
            } catch {
                Issue.record("unexpected \(error)")
            }
            #expect(log.items.last?.error?.kind == .connection)
            env.connection.stop()
        }

        @Test("the server saying no is not tried on the other address, and a wrong password is an error of the status")
        func authentication() async {
            let (env, log) = makeEnv(up: [Self.localHost, Self.publicHost])
            env.network.rejectPassword(true)
            env.connection.start()
            _ = await env.connection.resolvedRoute()
            let before = env.transport.requests.count
            do {
                _ = try await env.connection.artists()
                Issue.record("should have failed")
            } catch let error as SubsonicError {
                #expect(error.kind == .authentication)
            } catch {
                Issue.record("unexpected \(error)")
            }
            #expect(env.transport.requests.count == before + 1)
            #expect(log.items.last?.error?.kind == .authentication)
            env.connection.stop()
        }

        @Test("a song that is not there is not a problem of the connection")
        func notFound() async {
            let (env, log) = makeEnv(local: false, up: [Self.publicHost])
            env.connection.start()
            _ = await env.connection.resolvedRoute()
            do {
                _ = try await env.connection.song("gone")
                Issue.record("should have failed")
            } catch let error as SubsonicError {
                #expect(error.kind == .notFound)
            } catch {
                Issue.record("unexpected \(error)")
            }
            #expect(log.items.last?.error == nil)
            env.connection.stop()
        }

        @Test("test: every address on its own, nothing is reported")
        func testing() async {
            let (env, log) = makeEnv(up: [Self.publicHost])
            let results = await env.connection.test()
            #expect(results.map(\.route) == [.local, .public])
            if case .failure(let error) = results[0].outcome { #expect(error.kind == .connection) } else { Issue.record("local should fail") }
            #expect(results[1].outcome == .success("Navidrome 0.53.3 (API 1.16.1)"))
            #expect(log.items.isEmpty)
        }

        @Test("an artist's albums: the oldest first, those without a year last; all of them with their songs")
        func artistAlbums() async throws {
            let (env, _) = makeEnv(local: false, up: [Self.publicHost])
            let albums = try await env.connection.albums(ofArtist: "ar-1")
            #expect(albums.map(\.name) == ["Abba", "Arrival", "Undated"])

            // The stub answers every getAlbum the same: the count, the order of the songs and the progress matter here.
            var reported: [Int] = []
            let contents = try await env.connection.albumContents(ofArtist: "ar-1") { done, total in
                #expect(total == 3)
                reported.append(done)
            }
            #expect(contents.count == 3)
            #expect(contents[0].songs.map(\.title) == ["One", "Two", "Three"])
            #expect(reported == [0, 1, 2, 3])
        }
    }
}
