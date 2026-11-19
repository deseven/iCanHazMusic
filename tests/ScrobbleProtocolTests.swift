// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

private let fixedClock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

private func errorKind(_ body: () throws -> Void) -> ScrobbleError.Kind? {
    do {
        try body()
        return nil
    } catch let error as ScrobbleError {
        return error.kind
    } catch {
        return nil
    }
}

extension AllTests {
    // MARK: - Audioscrobbler: requests and answers

    @MainActor @Suite("Audioscrobbler API")
    struct AudioscrobblerAPITests {
        private let session = AudioscrobblerSession(
            id: "SID", nowPlayingURL: URL(string: "http://np.example.org/np")!,
            submissionURL: URL(string: "http://sub.example.org/sub")!)

        @Test("the token is md5(md5(password) + timestamp)")
        func token() {
            // md5("secret") = 5ebe2294ecd0e0f08eab7690d2a6ee69
            #expect(AudioscrobblerAPI.token(password: "secret", timestamp: 1_700_000_000) == "9daa2f47bfef02e5ea27ddbe47714ca8")
        }

        @Test("the handshake is a GET to the endpoint with all the parameters, and identifies the app")
        func handshake() throws {
            let request = try #require(AudioscrobblerAPI.handshakeRequest(
                endpoint: "https://post.example.org/scrobble", username: "a&b c", password: "secret",
                timestamp: 1_700_000_000, clientVersion: "9.9"))
            #expect(request.httpMethod == nil || request.httpMethod == "GET")
            #expect(request.url?.absoluteString.hasPrefix("https://post.example.org/scrobble/?hs=true&p=1.2.1&c=ich&v=9.9&u=a%26b%20c&t=1700000000&a=") == true)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent)
            #expect(request.timeoutInterval == ScrobbleHTTP.requestTimeout && ScrobbleHTTP.requestTimeout == 60)

            let query = HTTPStub.query(of: request)
            #expect(query["hs"] == "true" && query["p"] == "1.2.1" && query["c"] == "ich" && query["v"] == "9.9")
            #expect(query["u"] == "a&b c" && query["t"] == "1700000000")
            #expect(query["a"] == "9daa2f47bfef02e5ea27ddbe47714ca8")

            // An account name is optional.
            let anonymous = try #require(AudioscrobblerAPI.handshakeRequest(
                endpoint: "http://h.example.org", username: "", password: "x", timestamp: 1))
            #expect(HTTPStub.query(of: anonymous)["u"] == "")
        }

        @Test("now playing has every field, empty if not known")
        func nowPlaying() {
            let track = ScrobbleTestData.track(artist: "A&B=C+D é", title: "x y/z%", album: "Album", duration: 200.4, trackNumber: 7)
            let request = AudioscrobblerAPI.nowPlayingRequest(track, session: session)
            #expect(request.httpMethod == "POST")
            #expect(request.url == session.nowPlayingURL)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")

            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(!body.contains("A&B") && !body.contains("é"))     // everything is escaped
            #expect(StubTransport.form(of: request) == [
                "s": "SID", "a": "A&B=C+D é", "t": "x y/z%", "b": "Album", "l": "200", "n": "7", "m": "",
            ])

            let bare = AudioscrobblerAPI.nowPlayingRequest(ScrobbleTestData.track(album: "", duration: 0), session: session)
            let form = StubTransport.form(of: bare)
            #expect(form["b"] == "" && form["l"] == "" && form["n"] == "")
        }

        @Test("a submission is one track at index 0: the start time, the source P, the length")
        func submission() {
            let track = ScrobbleTestData.track(startedAt: Date(timeIntervalSince1970: 1_700_000_123), trackNumber: 3)
            let request = AudioscrobblerAPI.submissionRequest(track, session: session)
            #expect(request.httpMethod == "POST")
            #expect(request.url == session.submissionURL)
            #expect(StubTransport.form(of: request) == [
                "s": "SID", "a[0]": "Artist", "t[0]": "Title", "i[0]": "1700000123", "o[0]": "P", "r[0]": "",
                "l[0]": "200", "b[0]": "Album", "n[0]": "3", "m[0]": "",
            ])
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("a[0]=Artist"))          // the indexes are not escaped

            let withoutNumber = AudioscrobblerAPI.submissionRequest(ScrobbleTestData.track(trackNumber: 0), session: session)
            #expect(StubTransport.form(of: withoutNumber)["n[0]"] == "")
        }

        @Test("a handshake answer: OK with the session and two URLs")
        func handshakeOK() throws {
            let answer = ScrobbleAnswer.handshake(session: "S1", nowPlaying: "http://a/np", submission: "https://b/sub")
            let session = try AudioscrobblerAPI.parseHandshake(status: answer.status, body: answer.body)
            #expect(session == AudioscrobblerSession(id: "S1", nowPlayingURL: URL(string: "http://a/np")!,
                                                     submissionURL: URL(string: "https://b/sub")!))

            let crlf = Data("OK\r\nS2\r\nhttp://a/np\r\nhttp://b/sub\r\n".utf8)
            #expect(try AudioscrobblerAPI.parseHandshake(status: 200, body: crlf).id == "S2")
        }

        @Test("handshake failures are classified: refused credentials end the matter, the rest is worth another try")
        func handshakeFailures() {
            func kind(_ answer: StubTransport.Answer) -> ScrobbleError.Kind? {
                errorKind { _ = try AudioscrobblerAPI.parseHandshake(status: answer.status, body: answer.body) }
            }
            #expect(kind(ScrobbleAnswer.text("BADAUTH\n")) == .authentication)
            #expect(kind(ScrobbleAnswer.text("BANNED\n")) == .authentication)
            #expect(kind(ScrobbleAnswer.text("BADTIME\n")) == .authentication)
            #expect(kind(ScrobbleAnswer.text("FAILED Database down\n")) == .temporary)
            #expect(kind(ScrobbleAnswer.text("OK\nSID\n")) == .temporary)                       // incomplete
            #expect(kind(ScrobbleAnswer.text("OK\nSID\nnot a url\nhttp://x/\n")) == .temporary)
            #expect(kind(ScrobbleAnswer.text("<html>hello</html>")) == .temporary)
            #expect(kind(ScrobbleAnswer.serverError) == .temporary)
            #expect(kind(ScrobbleAnswer.text("", status: 404)) == .rejected)                    // a wrong address

            do {
                _ = try AudioscrobblerAPI.parseHandshake(status: 200, body: Data("FAILED Database down\n".utf8))
            } catch let error as ScrobbleError {
                #expect(error.message.contains("Database down"))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }

        @Test("the answer to a call is OK or BADSESSION, anything else is a failure")
        func replies() throws {
            #expect(try AudioscrobblerAPI.parseReply(status: 200, body: Data("OK\n".utf8)) == .ok)
            #expect(try AudioscrobblerAPI.parseReply(status: 200, body: Data("BADSESSION\n".utf8)) == .badSession)
            func kind(_ answer: StubTransport.Answer) -> ScrobbleError.Kind? {
                errorKind { _ = try AudioscrobblerAPI.parseReply(status: answer.status, body: answer.body) }
            }
            #expect(kind(ScrobbleAnswer.text("FAILED Bad stuff\n")) == .temporary)
            #expect(kind(ScrobbleAnswer.text("what?")) == .temporary)
            #expect(kind(ScrobbleAnswer.serverError) == .temporary)
        }
    }

    // MARK: - Audioscrobbler: client

    @MainActor @Suite("Audioscrobbler client")
    struct AudioscrobblerClientTests {
        /// Answers the handshake and the calls like a healthy server does, the calls with `call`.
        private func server(session: @escaping @Sendable (Int) -> String = { "SID\($0)" },
                            call: @escaping @Sendable (URLRequest, Int) -> StubTransport.Answer = { _, _ in ScrobbleAnswer.ok }) -> StubTransport {
            let handshakes = ScrobbleCounter()
            return StubTransport { request, index in
                if request.httpMethod == "POST" { return call(request, index) }
                return ScrobbleAnswer.handshake(session: session(handshakes.next()))
            }
        }

        private func client(_ transport: StubTransport) -> AudioscrobblerClient {
            AudioscrobblerClient(endpoint: "https://post.example.org", username: "bob", password: "secret",
                                 transport: transport, clock: fixedClock)
        }

        @Test("one handshake serves all the calls, which go to the URLs it gave")
        func session() async throws {
            let transport = server()
            let client = client(transport)
            try await client.nowPlaying(ScrobbleTestData.track(title: "1"))
            try await client.scrobble(ScrobbleTestData.track(title: "1"))
            try await client.scrobble(ScrobbleTestData.track(title: "2"))

            let requests = transport.requests
            #expect(requests.count == 4)
            #expect(requests.map { $0.httpMethod ?? "GET" } == ["GET", "POST", "POST", "POST"])
            #expect(requests[1].url?.absoluteString == "http://np.example.org/np")
            #expect(requests[2].url?.absoluteString == "http://sub.example.org/sub")
            #expect(requests.dropFirst().allSatisfy { StubTransport.form(of: $0)["s"] == "SID1" })
        }

        @Test("authenticating is the handshake, and gives the user name if there is one")
        func authenticate() async throws {
            let transport = server()
            #expect(try await client(transport).authenticate() == "bob")
            #expect(transport.requests.count == 1)
            let anonymous = AudioscrobblerClient(endpoint: "https://post.example.org", username: "", password: "x",
                                                 transport: server(), clock: fixedClock)
            #expect(try await anonymous.authenticate() == nil)
        }

        @Test("a refused handshake is an authentication error, and nothing is sent after it")
        func badAuth() async {
            let transport = StubTransport(always: ScrobbleAnswer.text("BADAUTH\n"))
            let client = client(transport)
            await #expect(throws: ScrobbleError.self) { try await client.authenticate() }
            do {
                try await client.scrobble(ScrobbleTestData.track())
                Issue.record("should fail")
            } catch let error as ScrobbleError {
                #expect(error.kind == .authentication)
            } catch {
                Issue.record("unexpected \(error)")
            }
            #expect(transport.requests.allSatisfy { $0.httpMethod != "POST" })
        }

        @Test("BADSESSION means a new handshake and the same call again")
        func badSession() async throws {
            let transport = server(call: { request, _ in
                StubTransport.form(of: request)["s"] == "SID1" ? ScrobbleAnswer.badSession : ScrobbleAnswer.ok
            })
            try await client(transport).scrobble(ScrobbleTestData.track(title: "x"))

            let requests = transport.requests
            #expect(requests.map { $0.httpMethod ?? "GET" } == ["GET", "POST", "GET", "POST"])
            #expect(StubTransport.form(of: requests[3])["s"] == "SID2")
            #expect(StubTransport.form(of: requests[3])["t[0]"] == "x")
        }

        @Test("a server that keeps calling the session invalid doesn't make the client loop")
        func badSessionAlways() async {
            let transport = server(call: { _, _ in ScrobbleAnswer.badSession })
            let client = client(transport)
            do {
                try await client.scrobble(ScrobbleTestData.track())
                Issue.record("should fail")
            } catch let error as ScrobbleError {
                #expect(error.kind == .temporary)
            } catch {
                Issue.record("unexpected \(error)")
            }
            #expect(transport.requests.count == 4)        // handshake, call, handshake, call
        }

        @Test("three failures in a row mean a new handshake before the next call")
        func threeFailures() async throws {
            let transport = server(call: { _, index in index < 4 ? ScrobbleAnswer.serverError : ScrobbleAnswer.ok })
            let client = client(transport)
            for _ in 1...3 {
                await #expect(throws: ScrobbleError.self) { try await client.scrobble(ScrobbleTestData.track()) }
            }
            try await client.scrobble(ScrobbleTestData.track())
            #expect(transport.requests.map { $0.httpMethod ?? "GET" } == ["GET", "POST", "POST", "POST", "GET", "POST"])
        }

        @Test("a lost connection is a temporary error")
        func networkFailure() async {
            let client = client(StubTransport { _, _ in throw URLError(.notConnectedToInternet) })
            do {
                try await client.authenticate()
                Issue.record("should fail")
            } catch let error as ScrobbleError {
                #expect(error.kind == .temporary)
            } catch {
                Issue.record("unexpected \(error)")
            }
        }

    }

    // MARK: - ListenBrainz

    @MainActor @Suite("ListenBrainz API")
    struct ListenBrainzTests {
        private let endpoint = "https://lb.example.org"

        @Test("a scrobble is a single listen with the time the track started at")
        func scrobble() throws {
            let track = ScrobbleTestData.track(startedAt: Date(timeIntervalSince1970: 1_700_000_123), trackNumber: 4)
            let request = try #require(ListenBrainzAPI.scrobbleRequest(track, endpoint: endpoint, token: "TOK"))
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://lb.example.org/1/submit-listens")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token TOK")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent)

            let json = StubTransport.json(of: request)
            #expect(json["listen_type"] as? String == "single")
            let listen = try #require((json["payload"] as? [[String: Any]])?.first)
            #expect(listen["listened_at"] as? Int == 1_700_000_123)
            let metadata = try #require(listen["track_metadata"] as? [String: Any])
            #expect(metadata["artist_name"] as? String == "Artist")
            #expect(metadata["track_name"] as? String == "Title")
            #expect(metadata["release_name"] as? String == "Album")
            let info = try #require(metadata["additional_info"] as? [String: Any])
            #expect(info["duration"] as? Int == 200 && info["tracknumber"] as? Int == 4)
            #expect(info["media_player"] as? String == AppConstants.appName)
            #expect(info["submission_client"] as? String == AppConstants.appName)
            #expect(info["submission_client_version"] as? String == AppConstants.appVersion)
        }

        @Test("now playing is a playing_now listen without a time, and leaves out what isn't known")
        func nowPlaying() throws {
            let track = ScrobbleTestData.track(album: "", duration: 0)
            let request = try #require(ListenBrainzAPI.nowPlayingRequest(track, endpoint: endpoint, token: "TOK"))
            let json = StubTransport.json(of: request)
            #expect(json["listen_type"] as? String == "playing_now")
            let listen = try #require((json["payload"] as? [[String: Any]])?.first)
            #expect(listen["listened_at"] == nil)
            let metadata = try #require(listen["track_metadata"] as? [String: Any])
            #expect(metadata["release_name"] == nil)
            let info = try #require(metadata["additional_info"] as? [String: Any])
            #expect(info["duration"] == nil && info["tracknumber"] == nil)
        }

        @Test("the token is validated with a GET")
        func validate() throws {
            let request = try #require(ListenBrainzAPI.validateRequest(endpoint: endpoint, token: "TOK"))
            #expect(request.httpMethod == nil || request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://lb.example.org/1/validate-token")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token TOK")
        }

        @Test("a valid token gives the account name, an invalid one is an authentication error")
        func validation() throws {
            let valid = ScrobbleAnswer.tokenValid(user: "alice")
            #expect(try ListenBrainzAPI.parseValidation(status: valid.status, body: valid.body) == "alice")
            func kind(_ answer: StubTransport.Answer) -> ScrobbleError.Kind? {
                errorKind { _ = try ListenBrainzAPI.parseValidation(status: answer.status, body: answer.body) }
            }
            #expect(kind(ScrobbleAnswer.tokenInvalid) == .authentication)
            #expect(kind(ScrobbleAnswer.lbError(401, "Invalid authorization token.")) == .authentication)
            #expect(kind(ScrobbleAnswer.serverError) == .temporary)
            #expect(kind(ScrobbleAnswer.text("<html>not ListenBrainz</html>")) == .temporary)
            #expect(kind(ScrobbleAnswer.lbError(404, "Not found")) == .rejected)
        }

        @Test("answers to a submission are classified")
        func classification() {
            func kind(_ answer: StubTransport.Answer) -> ScrobbleError.Kind? {
                errorKind { try ListenBrainzAPI.check(status: answer.status, body: answer.body) }
            }
            #expect(kind(ScrobbleAnswer.accepted) == nil)
            #expect(kind(ScrobbleAnswer.lbError(401, "Invalid authorization token.")) == .authentication)
            #expect(kind(ScrobbleAnswer.lbError(400, "Invalid JSON")) == .rejected)
            #expect(kind(ScrobbleAnswer.lbError(429, "Slow down")) == .temporary)
            #expect(kind(ScrobbleAnswer.serverError) == .temporary)
            #expect(kind(ScrobbleAnswer.lbError(503, "Maintenance")) == .temporary)
            #expect(kind(ScrobbleAnswer.lbError(404, "Nope")) == .rejected)

            let refused = ScrobbleAnswer.lbError(400, "Invalid JSON")
            do {
                try ListenBrainzAPI.check(status: refused.status, body: refused.body)
            } catch let error as ScrobbleError {
                #expect(error.message.contains("Invalid JSON"))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }

        @Test("clearing now playing is a POST with the token and an empty JSON body; a 404 is not an error")
        func clearNowPlaying() async throws {
            let request = try #require(ListenBrainzAPI.clearNowPlayingRequest(endpoint: endpoint, token: "TOK"))
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://lb.example.org/1/playing-now/delete")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token TOK")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent)
            #expect(StubTransport.json(of: request).isEmpty && request.httpBody != nil)

            func kind(_ answer: StubTransport.Answer) -> ScrobbleError.Kind? {
                errorKind { try ListenBrainzAPI.checkClear(status: answer.status, body: answer.body) }
            }
            #expect(kind(ScrobbleAnswer.accepted) == nil)
            #expect(kind(ScrobbleAnswer.lbError(404, "Nothing playing")) == nil)
            #expect(kind(ScrobbleAnswer.lbError(401, "Invalid authorization token.")) == .authentication)
            #expect(kind(ScrobbleAnswer.serverError) == .temporary)

            let transport = StubTransport(always: ScrobbleAnswer.accepted)
            let client = ListenBrainzClient(endpoint: endpoint, token: "TOK", transport: transport)
            #expect(client.canClearNowPlaying)
            try await client.clearNowPlaying()
            #expect(transport.requests.map { $0.url?.path } == ["/1/playing-now/delete"])
        }

        @Test("Audioscrobbler has no way to clear it, and sends nothing")
        func audioscrobblerCannotClear() async throws {
            let transport = StubTransport(always: ScrobbleAnswer.ok)
            let client = AudioscrobblerClient(endpoint: "https://post.example.org", username: "bob", password: "x",
                                              transport: transport, clock: fixedClock)
            #expect(!client.canClearNowPlaying)
            try await client.clearNowPlaying()
            #expect(transport.requests.isEmpty)
        }

        @Test("the client validates the token and submits")
        func client() async throws {
            let transport = StubTransport { request, _ in
                request.url?.path == "/1/validate-token" ? ScrobbleAnswer.tokenValid(user: "alice") : ScrobbleAnswer.accepted
            }
            let client = ListenBrainzClient(endpoint: endpoint, token: "TOK", transport: transport)
            #expect(try await client.authenticate() == "alice")
            try await client.nowPlaying(ScrobbleTestData.track())
            try await client.scrobble(ScrobbleTestData.track())
            #expect(transport.requests.map { $0.url?.path } == ["/1/validate-token", "/1/submit-listens", "/1/submit-listens"])
        }

        @Test("an empty token is an authentication error without a request")
        func emptyToken() async {
            let transport = StubTransport(always: ScrobbleAnswer.accepted)
            let client = ListenBrainzClient(endpoint: endpoint, token: "", transport: transport)
            do {
                try await client.authenticate()
                Issue.record("should fail")
            } catch let error as ScrobbleError {
                #expect(error.kind == .authentication)
            } catch {
                Issue.record("unexpected \(error)")
            }
            #expect(transport.requests.isEmpty)
        }
    }
}

/// A counter that can be used from the stub's handler.
final class ScrobbleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
