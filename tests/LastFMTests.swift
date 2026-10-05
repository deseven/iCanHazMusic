// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import iCanHazMusic

/// Counts how many calls are in flight at once.
private final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0

    var maxConcurrent: Int { lock.withLock { peak } }

    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
}

extension AllTests {
    // MARK: - API

    @MainActor @Suite("Last.fm API")
    struct LastFMAPITests {
        private let credentials = LastFMTestData.credentials

        @Test("the signature is the MD5 of the sorted name+value pairs and the secret")
        func signatureKnownValue() {
            // md5("api_keyKEYmethodauth.getTokenSECRET"); the same scheme was accepted by the real service.
            let signature = LastFMAPI.signature(for: ["method": "auth.getToken", "api_key": "KEY"], secret: "SECRET")
            #expect(signature == "66ee63a18da3c919f987b342697d913c")
        }

        @Test("the signature sorts by name, skips the format and signs unencoded values")
        func signatureRules() {
            let expected = Insecure.MD5.hash(data: Data("a1b&cé2S".utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(LastFMAPI.signature(for: ["b": "&cé2", "format": "json", "a": "1"], secret: "S") == expected)
        }

        @Test("a request is a signed POST with a 30 second limit, and values survive the encoding")
        func request() {
            let call = LastFMCall.updateNowPlaying(LastFMTestData.track(artist: "A&B=C+D é", title: "x y/z%"))
            let request = LastFMAPI.request(for: call, credentials: credentials, sessionKey: "SK")
            #expect(request.httpMethod == "POST")
            #expect(request.url == LastFMAPI.endpoint)
            #expect(request.timeoutInterval == 30)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent)
            #expect(AppConstants.userAgent.hasPrefix("iCanHazMusic/"))

            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(!body.contains("A&B"))
            let params = StubTransport.params(of: request)
            #expect(params["artist"] == "A&B=C+D é")
            #expect(params["track"] == "x y/z%")
            #expect(params["method"] == "track.updateNowPlaying")
            #expect(params["api_key"] == "KEY")
            #expect(params["sk"] == "SK")
            #expect(params["format"] == "json")

            var signed = params
            let signature = signed.removeValue(forKey: "api_sig")
            #expect(signature == LastFMAPI.signature(for: signed, secret: "SECRET"))
        }

        @Test("a now playing update carries what is known; a scrobble also when the track started")
        func trackParams() {
            let track = LastFMTestData.track(duration: 200.4)
            let nowPlaying = LastFMCall.updateNowPlaying(track).params
            #expect(nowPlaying == ["artist": "Artist", "track": "Title", "album": "Album", "duration": "200"])

            let scrobble = LastFMCall.scrobble(track)
            #expect(scrobble.method == "track.scrobble")
            #expect(scrobble.params["timestamp"] == "1700000000")

            let bare = LastFMCall.updateNowPlaying(LastFMTestData.track(album: "", duration: 0)).params
            #expect(bare == ["artist": "Artist", "track": "Title"])
        }

        @Test("errors are told apart: bad session is final, a down service temporary, a bad request is refused")
        func classification() {
            func kind(_ answer: StubTransport.Answer) -> LastFMError.Kind? {
                do {
                    _ = try LastFMAPI.check(status: answer.status, body: answer.body)
                    return nil
                } catch let error as LastFMError {
                    return error.kind
                } catch {
                    return nil
                }
            }
            #expect(kind(LastFMAnswer.error(9, "Invalid session key - Please re-authenticate")) == .authentication)
            #expect(kind(LastFMAnswer.error(4)) == .authentication)
            #expect(kind(LastFMAnswer.error(10)) == .authentication)
            #expect(kind(LastFMAnswer.error(26)) == .authentication)
            #expect(kind(LastFMAnswer.error(11)) == .temporary)
            #expect(kind(LastFMAnswer.error(16)) == .temporary)
            #expect(kind(LastFMAnswer.error(8)) == .temporary)
            #expect(kind(LastFMAnswer.error(29)) == .temporary)
            #expect(kind(LastFMAnswer.error(6, status: 400)) == .rejected)
            #expect(kind(LastFMAnswer.error(13, status: 400)) == .rejected)
            #expect(kind(LastFMAnswer.serverError) == .temporary)
            #expect(kind((502, Data())) == .temporary)
            #expect(kind((200, Data("not json".utf8))) == nil)     // a 2xx is a success, whatever it says
            #expect(kind(LastFMAnswer.ok) == nil)
        }

        @Test("the error keeps Last.fm's code and message")
        func errorDetails() throws {
            let answer = LastFMAnswer.error(9, "Invalid session key - Please re-authenticate")
            do {
                _ = try LastFMAPI.check(status: answer.status, body: answer.body)
                Issue.record("should have thrown")
            } catch let error as LastFMError {
                #expect(error.code == 9)
                #expect(error.message == "Invalid session key - Please re-authenticate")
            }
        }

        @Test("tokens and sessions are read from the answers; garbage is a temporary error")
        func parsing() throws {
            #expect(try LastFMAPI.parseToken(LastFMAnswer.token("abc").body) == "abc")
            #expect(try LastFMAPI.parseSession(LastFMAnswer.session(key: "K", name: "bob").body)
                == LastFMSession(key: "K", username: "bob"))
            #expect(throws: LastFMError.self) { try LastFMAPI.parseToken(Data("{}".utf8)) }
            #expect(throws: LastFMError.self) { try LastFMAPI.parseSession(Data(#"{"session":{"name":"x"}}"#.utf8)) }
        }

        @Test("authorization and profile URLs")
        func urls() {
            #expect(LastFMAPI.authorizationURL(credentials: credentials, token: "tok").absoluteString
                == "https://www.last.fm/api/auth/?api_key=KEY&token=tok")
            #expect(LastFMAPI.profileURL(username: "some_user-1")?.absoluteString == "https://www.last.fm/user/some_user-1")
            #expect(LastFMAPI.profileURL(username: "a b/c")?.absoluteString == "https://www.last.fm/user/a%20b/c")
        }

        @Test("credentials come from the obfuscated Info.plist values, and only if both are there and valid")
        func bundledCredentials() {
            let obfuscated = LastFMCredentials.obfuscated
            let info: [String: Any] = [LastFMCredentials.apiKeyInfoKey: obfuscated("k"),
                                       LastFMCredentials.secretInfoKey: obfuscated("s")]
            #expect(LastFMCredentials(infoDictionary: info) == LastFMCredentials(apiKey: "k", secret: "s"))
            #expect(LastFMCredentials(infoDictionary: [LastFMCredentials.apiKeyInfoKey: obfuscated("k")]) == nil)
            #expect(LastFMCredentials(infoDictionary: [LastFMCredentials.apiKeyInfoKey: obfuscated("k"),
                                                       LastFMCredentials.secretInfoKey: ""]) == nil)
            #expect(LastFMCredentials(infoDictionary: [LastFMCredentials.apiKeyInfoKey: "k",
                                                       LastFMCredentials.secretInfoKey: "s"]) == nil)   // not base64
            #expect(LastFMCredentials(infoDictionary: nil) == nil)
        }

        @Test("the obfuscation round-trips, and matches what build.sh writes")
        func obfuscation() {
            for text in ["KEY", "a-longer-secret-value-that-is-more-than-thirty-two-bytes-é", "x"] {
                let encoded = LastFMCredentials.obfuscated(text)
                #expect(encoded != text)
                #expect(LastFMCredentials.deobfuscated(encoded) == text)
            }
            // Made by obfuscate_credential in build.sh, with the key in LastFMCredentials.obfuscationKey.
            #expect(LastFMCredentials.deobfuscated("eXc9") == "KEY")
            #expect(LastFMCredentials.deobfuscated(
                "Ux8IWAsEAEVPQwZaSgMQHBIEWxRUH0QMVxEfWEscW1ZAV0lDDQILGhZYCktMH0lFEwoaA0hGVRcbpps=")
                == "a-longer-secret-value-that-is-more-than-thirty-two-bytes-é")
            #expect(LastFMCredentials.deobfuscated("") == nil)
            #expect(LastFMCredentials.deobfuscated("%%%") == nil)
        }
    }

    // MARK: - Queue

    @MainActor @Suite("Last.fm queue")
    struct LastFMQueueTests {
        private func call(_ title: String) -> LastFMCall {
            .scrobble(LastFMTestData.track(title: title))
        }

        private func makeQueue(_ transport: StubTransport, sleeps: SleepRecorder = SleepRecorder(),
                               onAuthenticationFailure: @escaping (LastFMError) -> Void = { _ in }) -> LastFMQueue {
            LastFMQueue(client: LastFMTestData.client(transport), sessionKey: "SK", sleep: sleeps.sleep,
                        onAuthenticationFailure: onAuthenticationFailure)
        }

        private func titles(_ transport: StubTransport) -> [String] {
            transport.params.compactMap { $0["track"] }
        }

        @Test("calls are sent one at a time, in the order they were added, with the session key")
        func sequential() async {
            let gauge = Gauge()
            let transport = StubTransport { _, _ in
                gauge.enter()
                defer { gauge.leave() }
                try await Task.sleep(for: .milliseconds(10))
                return LastFMAnswer.ok
            }
            let queue = makeQueue(transport)
            for title in ["1", "2", "3", "4"] { queue.enqueue(call(title), label: title) }

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(titles(transport) == ["1", "2", "3", "4"])
            #expect(gauge.maxConcurrent == 1)
            #expect(transport.params.allSatisfy { $0["sk"] == "SK" })
        }

        @Test("enqueueing doesn't wait for the network")
        func nonBlocking() {
            let transport = StubTransport { _, _ in
                try await Task.sleep(for: .seconds(60))
                return LastFMAnswer.ok
            }
            let queue = makeQueue(transport)
            queue.enqueue(call("1"), label: "1")
            queue.enqueue(call("2"), label: "2")
            #expect(queue.pendingCount == 2)
            queue.cancelAll()
        }

        @Test("a temporary failure is retried after 1, 2, 4 ... seconds, and the call then goes through")
        func retries() async {
            let sleeps = SleepRecorder()
            let transport = StubTransport { _, index in index < 4 ? LastFMAnswer.serverError : LastFMAnswer.ok }
            let queue = makeQueue(transport, sleeps: sleeps)
            queue.enqueue(call("1"), label: "1")
            queue.enqueue(call("2"), label: "2")

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(sleeps.seconds == [1, 2, 4, 8])
            #expect(titles(transport) == ["1", "1", "1", "1", "1", "2"])      // the second waited for the first
        }

        @Test("network failures and Last.fm being busy count as temporary")
        func otherTemporaryFailures() async {
            let transport = StubTransport { _, index in
                switch index {
                case 0: throw URLError(.timedOut)
                case 1: return LastFMAnswer.error(16, "temporarily unavailable", status: 500)
                case 2: return LastFMAnswer.error(29, "rate limit")
                default: return LastFMAnswer.ok
                }
            }
            let sleeps = SleepRecorder()
            let queue = makeQueue(transport, sleeps: sleeps)
            queue.enqueue(call("1"), label: "1")

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(sleeps.seconds == [1, 2, 4])
            #expect(transport.requests.count == 4)
        }

        @Test("a call is tried 10 times at most, then dropped, and the next one is sent")
        func givesUp() async {
            let sleeps = SleepRecorder()
            let transport = StubTransport { request, _ in
                StubTransport.params(of: request)["track"] == "bad" ? LastFMAnswer.serverError : LastFMAnswer.ok
            }
            let queue = makeQueue(transport, sleeps: sleeps)
            queue.enqueue(call("bad"), label: "bad")
            queue.enqueue(call("good"), label: "good")

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(titles(transport) == Array(repeating: "bad", count: 10) + ["good"])
            #expect(sleeps.seconds == [1, 2, 4, 8, 16, 32, 64, 128, 256])
        }

        @Test("the delay doubles")
        func delays() {
            #expect([1, 2, 3, 4, 10].map { LastFMQueue.delay(afterAttempt: $0) }
                == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(512)])
        }

        @Test("a request that is refused for itself is dropped without retries")
        func rejected() async {
            let sleeps = SleepRecorder()
            let transport = StubTransport { request, _ in
                StubTransport.params(of: request)["track"] == "bad"
                    ? LastFMAnswer.error(6, "Invalid parameters", status: 400) : LastFMAnswer.ok
            }
            let queue = makeQueue(transport, sleeps: sleeps)
            queue.enqueue(call("bad"), label: "bad")
            queue.enqueue(call("good"), label: "good")

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(titles(transport) == ["bad", "good"])
            #expect(sleeps.seconds.isEmpty)
        }

        @Test("an invalid session ends everything at once: nothing more is sent, the failure is reported once")
        func invalidSession() async {
            let sleeps = SleepRecorder()
            let transport = StubTransport(always: LastFMAnswer.error(9, "Invalid session key - Please re-authenticate"))
            var failures: [LastFMError] = []
            let queue = makeQueue(transport, sleeps: sleeps) { failures.append($0) }
            queue.enqueue(call("1"), label: "1")
            queue.enqueue(call("2"), label: "2")

            #expect(await waitUntil { !failures.isEmpty })
            #expect(queue.pendingCount == 0)
            #expect(failures.count == 1 && failures[0].code == 9)
            #expect(sleeps.seconds.isEmpty)

            try? await Task.sleep(for: .milliseconds(50))
            #expect(transport.requests.count == 1)
            #expect(failures.count == 1)
        }

        @Test("cancelling forgets everything pending, also what is being sent or waiting for a retry")
        func cancelAll() async {
            let transport = StubTransport { _, _ in
                try await Task.sleep(for: .seconds(60))
                return LastFMAnswer.ok
            }
            let queue = makeQueue(transport)
            queue.enqueue(call("1"), label: "1")
            queue.enqueue(call("2"), label: "2")
            #expect(await waitUntil { transport.requests.count == 1 })

            queue.cancelAll()
            #expect(queue.pendingCount == 0)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(transport.requests.count == 1)

            // It is usable again afterwards.
            let fresh = StubTransport(always: LastFMAnswer.ok)
            let other = makeQueue(fresh)
            other.enqueue(call("3"), label: "3")
            #expect(await waitUntil { other.pendingCount == 0 })
        }

        @Test("cancelling during a retry wait sends nothing more")
        func cancelDuringBackoff() async {
            let transport = StubTransport(always: LastFMAnswer.serverError)
            let blocked = BlockingSleep()
            let queue = LastFMQueue(client: LastFMTestData.client(transport), sessionKey: "SK",
                                    sleep: blocked.sleep, onAuthenticationFailure: { _ in })
            queue.enqueue(call("1"), label: "1")
            #expect(await waitUntil { blocked.waiting })

            queue.cancelAll()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(transport.requests.count == 1)
            #expect(queue.pendingCount == 0)
        }

        @Test("a now playing update waiting behind others is replaced by a newer one; the one being sent stays")
        func nowPlayingReplaced() {
            let transport = StubTransport { _, _ in
                try await Task.sleep(for: .seconds(60))
                return LastFMAnswer.ok
            }
            let queue = makeQueue(transport)
            let first = LastFMTestData.track(title: "first")
            queue.enqueue(.updateNowPlaying(first), label: "np1")
            queue.enqueue(.updateNowPlaying(LastFMTestData.track(title: "second")), label: "np2")
            queue.enqueue(.scrobble(first), label: "scrobble")
            queue.enqueue(.updateNowPlaying(LastFMTestData.track(title: "third")), label: "np3")
            #expect(queue.pendingCount == 3)      // np1 (in flight), scrobble, np3
            queue.cancelAll()
        }
    }

    // MARK: - Authorization

    @MainActor @Suite("Last.fm authorization")
    struct LastFMAuthTests {
        private let credentials = LastFMTestData.credentials

        /// Answers like Last.fm: a token, then "not authorized" until `authorizedAtCheck` checks were made.
        private func transport(authorizedAtCheck: Int) -> StubTransport {
            StubTransport { request, index in
                switch StubTransport.params(of: request)["method"] {
                case "auth.getToken": return LastFMAnswer.token("tok")
                case "auth.getSession":
                    // index 0 was getToken
                    return index >= authorizedAtCheck + 1
                        ? LastFMAnswer.session(key: "K", name: "bob")
                        : LastFMAnswer.error(14, "Unauthorized Token - This token has not been authorized")
                default: return LastFMAnswer.ok
                }
            }
        }

        private func makeAuth(_ transport: StubTransport, poll: Duration = .milliseconds(10),
                              opened: @escaping (URL) -> Void = { _ in }) -> LastFMAuth {
            LastFMAuth(client: LastFMTestData.client(transport), pollInterval: poll, openURL: opened)
        }

        @Test("opens the confirmation page, asks again while it isn't confirmed, and ends with the session")
        func fullFlow() async {
            let transport = transport(authorizedAtCheck: 2)
            var opened: [URL] = []
            let auth = makeAuth(transport) { opened.append($0) }

            let outcome = await auth.run()
            #expect(outcome == .connected(LastFMSession(key: "K", username: "bob")))
            #expect(opened.map(\.absoluteString) == ["https://www.last.fm/api/auth/?api_key=KEY&token=tok"])
            #expect(transport.methods == ["auth.getToken", "auth.getSession", "auth.getSession", "auth.getSession"])
            #expect(StubTransport.params(of: transport.requests[1])["token"] == "tok")
        }

        @Test("coming back to the app checks right away, without waiting for the interval")
        func checkNow() async {
            let transport = transport(authorizedAtCheck: 0)
            var opened = false
            let auth = makeAuth(transport, poll: .seconds(3600)) { _ in opened = true }
            let task = Task { await auth.run() }

            #expect(await waitUntil { opened })
            auth.checkNow()
            let outcome = await task.value
            #expect(outcome == .connected(LastFMSession(key: "K", username: "bob")))
        }

        @Test("aborting stops the checks and gives nothing")
        func abort() async {
            let transport = transport(authorizedAtCheck: .max - 1)
            let auth = makeAuth(transport)
            let task = Task { await auth.run() }

            #expect(await waitUntil { transport.requests.count >= 3 })
            task.cancel()
            #expect(await task.value == .aborted)

            let count = transport.requests.count
            try? await Task.sleep(for: .milliseconds(60))
            #expect(transport.requests.count == count)
        }

        @Test("aborting while the token is being fetched")
        func abortEarly() async {
            let transport = StubTransport { _, _ in
                try await Task.sleep(for: .seconds(60))
                return LastFMAnswer.token()
            }
            var opened = false
            let task = Task { await makeAuth(transport) { _ in opened = true }.run() }
            #expect(await waitUntil { transport.requests.count == 1 })
            task.cancel()
            #expect(await task.value == .aborted)
            #expect(!opened)
        }

        @Test("no token, no page: the flow fails with Last.fm's explanation")
        func tokenFails() async {
            let transport = StubTransport(always: LastFMAnswer.error(10, "Invalid API key"))
            var opened = false
            let outcome = await makeAuth(transport) { _ in opened = true }.run()
            guard case .failed(let message) = outcome else {
                Issue.record("expected a failure, got \(outcome)")
                return
            }
            #expect(message.contains("Invalid API key"))
            #expect(!opened)
        }

        @Test("a token that expired or isn't valid ends the flow")
        func sessionFails() async {
            let transport = StubTransport { request, _ in
                StubTransport.params(of: request)["method"] == "auth.getToken"
                    ? LastFMAnswer.token() : LastFMAnswer.error(4, "Unauthorized Token - This token has not been issued")
            }
            let outcome = await makeAuth(transport).run()
            guard case .failed(let message) = outcome else {
                Issue.record("expected a failure, got \(outcome)")
                return
            }
            #expect(message.contains("has not been issued"))
        }

        @Test("a failing connection while waiting is no reason to give up")
        func networkTrouble() async {
            let transport = StubTransport { request, index in
                switch StubTransport.params(of: request)["method"] {
                case "auth.getToken": return LastFMAnswer.token()
                default:
                    if index < 3 { throw URLError(.notConnectedToInternet) }
                    if index == 3 { return LastFMAnswer.serverError }
                    return LastFMAnswer.session()
                }
            }
            let outcome = await makeAuth(transport).run()
            #expect(outcome == .connected(LastFMSession(key: "sess", username: "someone")))
        }
    }

    // MARK: - Service

    @MainActor @Suite("Last.fm service")
    struct LastFMServiceTests {
        private struct Env {
            let paths: AppPaths
            let config: ConfigStore
            let transport: StubTransport
            let sleeps: SleepRecorder
            let service: LastFMService
        }

        private func makeEnv(connected: Bool = false, credentials: LastFMCredentials? = LastFMTestData.credentials,
                             transport: StubTransport? = nil) throws -> Env {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            if connected {
                config.update { $0.integrations.lastfm = AppConfig.Integrations.LastFM(session: "K", username: "bob") }
            }
            let transport = transport ?? StubTransport { request, _ in
                switch StubTransport.params(of: request)["method"] {
                case "auth.getToken": LastFMAnswer.token()
                case "auth.getSession": LastFMAnswer.session(key: "NEW", name: "alice")
                default: LastFMAnswer.ok
                }
            }
            let sleeps = SleepRecorder()
            let service = LastFMService(configStore: config, credentials: credentials, transport: transport,
                                        pollInterval: .milliseconds(10), sleep: sleeps.sleep)
            return Env(paths: paths, config: config, transport: transport, sleeps: sleeps, service: service)
        }

        @Test("not connected by default, and nothing is sent")
        func idle() async throws {
            let env = try makeEnv()
            #expect(!env.service.isConnected && env.service.username == nil && env.service.isAvailable)
            env.service.trackDidStart(LastFMTestData.track())
            env.service.trackDidEnd(LastFMTestData.track(), playedSeconds: 200)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.isEmpty)
        }

        @Test("connecting saves the session and the user name, and turns the integration on")
        func connect() async throws {
            let env = try makeEnv()
            var opened: [URL] = []
            let outcome = await env.service.connect { opened.append($0) }

            #expect(outcome == .connected(LastFMSession(key: "NEW", username: "alice")))
            #expect(env.service.isConnected && env.service.username == "alice")
            #expect(!env.service.isAuthorizing)
            #expect(env.config.config.integrations.lastfm == AppConfig.Integrations.LastFM(session: "NEW", username: "alice"))
            #expect(opened.count == 1)

            env.service.trackDidStart(LastFMTestData.track())
            #expect(await waitUntil { env.transport.methods.last == "track.updateNowPlaying" })
            #expect(StubTransport.params(of: env.transport.requests.last!)["sk"] == "NEW")
        }

        @Test("aborting leaves everything as it was")
        func abort() async throws {
            let env = try makeEnv(transport: StubTransport { request, _ in
                StubTransport.params(of: request)["method"] == "auth.getToken"
                    ? LastFMAnswer.token() : LastFMAnswer.error(14)
            })
            let task = Task { await env.service.connect { _ in } }
            #expect(await waitUntil { env.service.isAuthorizing })
            env.service.abortConnecting()

            #expect(await task.value == .aborted)
            #expect(!env.service.isAuthorizing && !env.service.isConnected)
            #expect(env.config.config.integrations.lastfm == AppConfig.Integrations.LastFM())
        }

        @Test("a failed connection is reported and changes nothing")
        func connectFails() async throws {
            let env = try makeEnv(transport: StubTransport(always: LastFMAnswer.error(11, "offline")))
            // Temporary errors while fetching the token end the attempt: there is nothing to wait for yet.
            let outcome = await env.service.connect { _ in }
            guard case .failed = outcome else {
                Issue.record("expected a failure, got \(outcome)")
                return
            }
            #expect(!env.service.isConnected)
            #expect(env.config.config.integrations.lastfm == AppConfig.Integrations.LastFM())
        }

        @Test("coming back to the app while connecting speeds the check up")
        func becomingActive() async throws {
            let transport = StubTransport { request, _ in
                StubTransport.params(of: request)["method"] == "auth.getToken" ? LastFMAnswer.token() : LastFMAnswer.session()
            }
            let dir = try TempDir()
            let config = ConfigStore(paths: AppPaths(workDir: dir.path("work")), saveDelay: .seconds(60))
            let service = LastFMService(configStore: config, credentials: LastFMTestData.credentials,
                                        transport: transport, pollInterval: .seconds(3600))
            let task = Task { await service.connect { _ in } }
            #expect(await waitUntil { transport.requests.count == 1 })
            service.appDidBecomeActive()
            #expect(await task.value == .connected(LastFMSession(key: "sess", username: "someone")))
        }

        @Test("a saved session is used from the start")
        func savedSession() async throws {
            let env = try makeEnv(connected: true)
            #expect(env.service.isConnected && env.service.username == "bob")
            env.service.trackDidStart(LastFMTestData.track(artist: "Foo", title: "Bar"))
            #expect(await waitUntil { env.transport.requests.count == 1 })
            let params = env.transport.params[0]
            #expect(params["method"] == "track.updateNowPlaying")
            #expect(params["sk"] == "K" && params["artist"] == "Foo" && params["track"] == "Bar")
            #expect(params["timestamp"] == nil)
        }

        @Test("a build without credentials can't connect, and keeps the saved session")
        func noCredentials() async throws {
            let env = try makeEnv(connected: true, credentials: nil)
            #expect(!env.service.isAvailable && !env.service.isConnected)
            #expect(env.config.config.integrations.lastfm.session == "K")

            if case .failed = await env.service.connect(openURL: { _ in }) {} else { Issue.record("should fail") }
            env.service.trackDidStart(LastFMTestData.track())
            #expect(env.transport.requests.isEmpty)
        }

        @Test("a track is scrobbled when it is left after at least half of it was played")
        func scrobbling() async throws {
            let env = try makeEnv(connected: true)
            let started = Date(timeIntervalSince1970: 1_700_000_123)
            func track(_ title: String, duration: TimeInterval = 200, artist: String = "Artist") -> PlayedTrack {
                LastFMTestData.track(artist: artist, title: title, duration: duration, startedAt: started)
            }
            env.service.trackDidEnd(track("short of half"), playedSeconds: 99)
            env.service.trackDidEnd(track("too short to scrobble", duration: 29), playedSeconds: 29)
            env.service.trackDidEnd(track("no duration", duration: 0), playedSeconds: 500)
            env.service.trackDidEnd(track("no artist", artist: "  "), playedSeconds: 200)
            env.service.trackDidEnd(track("half"), playedSeconds: 100)
            env.service.trackDidEnd(track("short but whole", duration: 30), playedSeconds: 30)

            #expect(await waitUntil { env.transport.requests.count == 2 })
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.params.map { $0["track"] } == ["half", "short but whole"])
            let first = env.transport.params[0]
            #expect(first["method"] == "track.scrobble")
            #expect(first["timestamp"] == "1700000123")
            #expect(first["sk"] == "K")
            #expect(first["duration"] == "200")
        }

        @Test("tracks without tags are neither announced nor scrobbled")
        func untaggedTracks() async throws {
            let env = try makeEnv(connected: true)
            for track in [LastFMTestData.track(artist: TagFallback.artist),
                          LastFMTestData.track(title: TagFallback.title)] {
                env.service.trackDidStart(track)
                env.service.trackDidEnd(track, playedSeconds: 200)
            }
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.isEmpty)

            env.service.trackDidStart(LastFMTestData.track(album: TagFallback.album))   // an unknown album is fine
            #expect(await waitUntil { env.transport.requests.count == 1 })
        }

        @Test("the scrobble rule")
        func rule() {
            let track = LastFMTestData.track(duration: 100)
            #expect(LastFMService.isScrobbleWorthy(track, playedSeconds: 50))
            #expect(!LastFMService.isScrobbleWorthy(track, playedSeconds: 49.9))
            #expect(LastFMService.isScrobbleWorthy(track, playedSeconds: 100))
            #expect(!LastFMService.isScrobbleWorthy(LastFMTestData.track(duration: 29.9), playedSeconds: 29.9))
        }

        @Test("disconnecting drops what's pending and removes the session from the config")
        func disconnect() async throws {
            let transport = StubTransport { _, _ in
                try await Task.sleep(for: .seconds(60))
                return LastFMAnswer.ok
            }
            let env = try makeEnv(connected: true, transport: transport)
            env.service.trackDidStart(LastFMTestData.track(title: "1"))
            env.service.trackDidStart(LastFMTestData.track(title: "2"))
            env.service.trackDidEnd(LastFMTestData.track(title: "1"), playedSeconds: 200)
            #expect(await waitUntil { transport.requests.count == 1 })

            env.service.disconnect()
            #expect(!env.service.isConnected && env.service.username == nil)
            #expect(env.config.config.integrations.lastfm == AppConfig.Integrations.LastFM())

            env.service.trackDidStart(LastFMTestData.track(title: "3"))
            env.service.trackDidEnd(LastFMTestData.track(title: "3"), playedSeconds: 200)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(transport.requests.count == 1)

            env.config.flush()
            let saved = try String(contentsOf: env.paths.configURL, encoding: .utf8)
            #expect(!saved.contains("\"K\""))
        }

        @Test("a session Last.fm doesn't accept disconnects at once and says why")
        func sessionRefused() async throws {
            let transport = StubTransport(always: LastFMAnswer.error(9, "Invalid session key - Please re-authenticate"))
            let env = try makeEnv(connected: true, transport: transport)
            var messages: [String] = []
            env.service.onConnectionLost = { messages.append($0) }

            env.service.trackDidStart(LastFMTestData.track())
            env.service.trackDidStart(LastFMTestData.track(title: "other"))
            #expect(await waitUntil { !messages.isEmpty })

            #expect(!env.service.isConnected)
            #expect(env.config.config.integrations.lastfm == AppConfig.Integrations.LastFM())
            #expect(messages.count == 1)
            #expect(messages[0].contains("Invalid session key") && messages[0].contains("bob"))
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.count == 1)
            #expect(env.sleeps.seconds.isEmpty)
        }

        @Test("temporary trouble doesn't disconnect")
        func temporaryTrouble() async throws {
            let transport = StubTransport { _, index in index < 2 ? LastFMAnswer.serverError : LastFMAnswer.ok }
            let env = try makeEnv(connected: true, transport: transport)
            var lost = false
            env.service.onConnectionLost = { _ in lost = true }

            env.service.trackDidStart(LastFMTestData.track())
            #expect(await waitUntil { transport.requests.count == 3 })
            #expect(env.service.isConnected && !lost)
            #expect(env.sleeps.seconds == [1, 2])
        }
    }

    // MARK: - Play progress

    @MainActor @Suite("Play progress")
    struct PlayProgressTests {
        @Test("normal progress adds up, jumps and going back don't, and a pause (same position) adds nothing")
        func observing() {
            var progress = PlayProgress(track: LastFMTestData.track())
            for second in stride(from: 0.25, through: 2, by: 0.25) { progress.observe(position: second) }
            #expect(abs(progress.played - 2) < 1e-9)

            progress.observe(position: 2)            // paused
            #expect(abs(progress.played - 2) < 1e-9)

            progress.observe(position: 90)           // seek forward
            #expect(abs(progress.played - 2) < 1e-9)
            progress.observe(position: 90.25)
            #expect(abs(progress.played - 2.25) < 1e-9)

            progress.observe(position: 10)           // seek back
            progress.observe(position: 10.5)
            #expect(abs(progress.played - 2.75) < 1e-9)
        }
    }
}

/// A `sleep` that stays in the wait until cancelled.
private final class BlockingSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = false

    var waiting: Bool { lock.withLock { inside } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] _ in
            lock.withLock { inside = true }
            try await Task.sleep(for: .seconds(60))
        }
    }
}
