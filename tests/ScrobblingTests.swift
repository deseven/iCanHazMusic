// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    // MARK: - Rule

    @MainActor @Suite("Scrobble rule")
    struct ScrobbleRuleTests {
        @Test("a track counts after half of it or 4 minutes, whichever comes first")
        func threshold() {
            #expect(ScrobbleRule.threshold(forDuration: 100) == 50)
            #expect(ScrobbleRule.threshold(forDuration: 480) == 240)
            #expect(ScrobbleRule.threshold(forDuration: 1000) == 240)
        }

        @Test("worth scrobbling: long enough, listened to enough")
        func worthy() {
            let track = ScrobbleTestData.track(duration: 100)
            #expect(ScrobbleRule.isScrobbleWorthy(track, playedSeconds: 50))
            #expect(!ScrobbleRule.isScrobbleWorthy(track, playedSeconds: 49.9))
            #expect(ScrobbleRule.isScrobbleWorthy(track, playedSeconds: 100))
            #expect(!ScrobbleRule.isScrobbleWorthy(ScrobbleTestData.track(duration: 29.9), playedSeconds: 29.9))
            #expect(ScrobbleRule.isScrobbleWorthy(ScrobbleTestData.track(duration: 30), playedSeconds: 15))
            #expect(!ScrobbleRule.isScrobbleWorthy(ScrobbleTestData.track(duration: 0), playedSeconds: 500))

            let long = ScrobbleTestData.track(duration: 1000)
            #expect(ScrobbleRule.isScrobbleWorthy(long, playedSeconds: 240))
            #expect(!ScrobbleRule.isScrobbleWorthy(long, playedSeconds: 239))
        }

        @Test("a track needs a real artist and title")
        func reportable() {
            #expect(ScrobbleRule.isReportable(ScrobbleTestData.track()))
            #expect(ScrobbleRule.isReportable(ScrobbleTestData.track(album: TagFallback.album)))   // an unknown album is fine
            #expect(!ScrobbleRule.isReportable(ScrobbleTestData.track(artist: "  ")))
            #expect(!ScrobbleRule.isReportable(ScrobbleTestData.track(title: "")))
            #expect(!ScrobbleRule.isReportable(ScrobbleTestData.track(artist: TagFallback.artist)))
            #expect(!ScrobbleRule.isReportable(ScrobbleTestData.track(title: TagFallback.title)))
        }
    }

    // MARK: - Settings of one service

    @MainActor @Suite("Scrobble service settings")
    struct ScrobbleServiceConfigTests {
        @Test("endpoints are normalized: http(s) only, no trailing slash, no query")
        func endpoints() {
            let normalize = ScrobbleServiceConfig.normalizedEndpoint
            #expect(normalize("https://api.listenbrainz.org") == "https://api.listenbrainz.org")
            #expect(normalize("https://api.listenbrainz.org/") == "https://api.listenbrainz.org")
            #expect(normalize("  HTTP://Example.ORG:8080/apis/audioscrobbler//  ") == "http://example.org:8080/apis/audioscrobbler")
            #expect(normalize("http://192.168.1.5:42010/") == "http://192.168.1.5:42010")
            #expect(normalize("") == nil)
            #expect(normalize("example.org") == nil)
            #expect(normalize("ftp://example.org") == nil)
            #expect(normalize("https://") == nil)
            #expect(normalize("https://example.org/?token=1") == nil)
            #expect(normalize("https://example.org/#x") == nil)
            #expect(normalize("https://user:pw@example.org") == nil)
        }

        @Test("settings that can't be saved say why; the name has to be unique")
        func problems() {
            let one = ScrobbleServiceConfig(name: "One", type: .listenbrainz, endpoint: "https://x.org", secret: "t")
            #expect(one.problem(among: []) == nil)
            #expect(one.problem(among: [one]) == nil)       // itself doesn't count

            var other = one
            other.id = UUID()
            #expect(one.problem(among: [other]) != nil)
            other.name = " ONE "
            #expect(one.problem(among: [other]) != nil)      // the same name, however it is written
            other.name = "Two"
            #expect(one.problem(among: [other]) == nil)

            var broken = one
            broken.name = "  "
            #expect(broken.problem(among: []) != nil)
            broken = one
            broken.endpoint = "nope"
            #expect(broken.problem(among: []) != nil)
            broken = one
            broken.secret = ""
            #expect(broken.problem(among: []) != nil)
            broken = one
            broken.type = .audioscrobbler
            broken.username = ""                               // optional there
            #expect(broken.problem(among: []) == nil)
        }

        @Test("normalizing trims the name and the account, and a token, but not a password")
        func normalizing() {
            let password = ScrobbleServiceConfig(name: " A ", type: .audioscrobbler, endpoint: "https://x.org/",
                                                 username: " bob ", secret: " pw ")
            #expect(password.normalized.name == "A" && password.normalized.username == "bob")
            #expect(password.normalized.endpoint == "https://x.org" && password.normalized.secret == " pw ")

            let token = ScrobbleServiceConfig(name: "B", type: .listenbrainz, endpoint: "https://x.org", secret: " tok\n")
            #expect(token.normalized.secret == "tok")
        }

        @Test("only what decides the server and the account needs a new connection")
        func sameConnection() {
            let base = ScrobbleServiceConfig(name: "A", type: .audioscrobbler, endpoint: "https://x.org", username: "u", secret: "s")
            var changed = base
            changed.name = "B"
            changed.submitNowPlaying = false
            changed.enabled = false
            #expect(base.hasSameConnection(as: changed))
            for edit in [{ (s: inout ScrobbleServiceConfig) in s.endpoint = "https://y.org" },
                         { $0.username = "v" }, { $0.secret = "t" }, { $0.type = .listenbrainz }] {
                var other = base
                edit(&other)
                #expect(!base.hasSameConnection(as: other))
            }
        }

        @Test("services are ordered by name as a person would")
        func ordering() {
            func service(_ name: String) -> ScrobbleServiceConfig {
                ScrobbleServiceConfig(name: name, type: .listenbrainz, endpoint: "https://x.org")
            }
            let sorted = [service("b"), service("Z"), service("a"), service("10"), service("9")]
                .sorted(by: ScrobbleServiceConfig.isOrderedBefore)
            #expect(sorted.map(\.name) == ["9", "10", "a", "b", "Z"])
        }

        @Test("every type has common endpoints that are valid as they are")
        func commonEndpoints() {
            for kind in ScrobbleServiceConfig.Kind.allCases {
                #expect(!kind.commonEndpoints.isEmpty)
                for common in kind.commonEndpoints {
                    #expect(ScrobbleServiceConfig.normalizedEndpoint(common.url) == common.url)
                }
            }
            #expect(ScrobbleServiceConfig.Kind.audioscrobbler.usesUsername)
            #expect(!ScrobbleServiceConfig.Kind.listenbrainz.usesUsername)
        }

        @Test("obfuscated text reads back, nothing readable is left, and what isn't ours isn't read")
        func obfuscation() {
            for text in ["", "p", "token-123", "pässwörd 密码 🔑", String(repeating: "long ", count: 40)] {
                let encoded = Obfuscation.obfuscated(text)
                #expect(Obfuscation.deobfuscated(encoded) == text)
                if text.count > 3 { #expect(!encoded.contains(text)) }
            }
            #expect(Obfuscation.obfuscated("") == "")
            #expect(Obfuscation.obfuscated("a") != Obfuscation.obfuscated("b"))
            #expect(Obfuscation.deobfuscated("%%% not base64") == nil)
            #expect(Obfuscation.deobfuscated(Data([0xFF, 0xFE]).base64EncodedString()) == nil)    // not UTF-8 once unmasked
        }
    }

    // MARK: - Queue

    @MainActor @Suite("Scrobble queue")
    struct ScrobbleQueueTests {
        private func scrobble(_ title: String) -> ScrobbleQueue.Call {
            .scrobble(ScrobbleTestData.track(title: title))
        }

        private func makeQueue(_ client: FakeScrobbleClient, sleeps: SleepRecorder = SleepRecorder(),
                               onDelivered: @escaping (ScrobbleQueue.Call) -> Void = { _ in },
                               onFailure: @escaping (ScrobbleError) -> Void = { _ in }) -> ScrobbleQueue {
            ScrobbleQueue(name: "test", client: client, sleep: sleeps.sleep, onDelivered: onDelivered, onFailure: onFailure)
        }

        private nonisolated static let temporary = ScrobbleError(.temporary, "server down")

        @Test("calls are sent one at a time, in the order they were added")
        func sequential() async {
            let gauge = Gauge()
            let client = FakeScrobbleClient { _, _ in
                gauge.enter()
                defer { gauge.leave() }
                try await Task.sleep(for: .milliseconds(10))
                return nil
            }
            let queue = makeQueue(client)
            for title in ["1", "2", "3", "4"] { queue.enqueue(scrobble(title), label: title) }

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(client.scrobbled == ["1", "2", "3", "4"])
            #expect(gauge.maxConcurrent == 1)
        }

        @Test("enqueueing doesn't wait for the network")
        func nonBlocking() {
            let client = FakeScrobbleClient { _, _ in
                try await Task.sleep(for: .seconds(60))
                return nil
            }
            let queue = makeQueue(client)
            queue.enqueue(scrobble("1"), label: "1")
            queue.enqueue(scrobble("2"), label: "2")
            #expect(queue.pendingCount == 2)
            queue.cancelAll()
        }

        @Test("authenticating is a call like the others")
        func authenticating() async {
            let client = FakeScrobbleClient { call, _ in call == .authenticate ? "bob" : nil }
            var delivered: [ScrobbleQueue.Call] = []
            let queue = makeQueue(client, onDelivered: { delivered.append($0) })
            queue.enqueue(.authenticate, label: "authentication")
            queue.enqueue(scrobble("1"), label: "1")

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(client.calls == [.authenticate, .scrobble("1")])
            let expected: [ScrobbleQueue.Call] = [.authenticate, scrobble("1")]
            #expect(delivered == expected)
        }

        @Test("a temporary failure is retried after 1, 2, 4 ... seconds, and the call then goes through")
        func retries() async {
            let sleeps = SleepRecorder()
            let client = FakeScrobbleClient { _, index in
                if index < 4 { throw Self.temporary }
                return nil
            }
            var failures: [ScrobbleError] = []
            let queue = makeQueue(client, sleeps: sleeps, onFailure: { failures.append($0) })
            queue.enqueue(scrobble("1"), label: "1")
            queue.enqueue(scrobble("2"), label: "2")

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(sleeps.seconds == [1, 2, 4, 8])
            #expect(client.scrobbled == ["1", "1", "1", "1", "1", "2"])      // the second waited for the first
            #expect(failures.count == 4)                                       // every failed try is reported
        }

        @Test("a call is tried 10 times at most, then dropped, and the next one is sent")
        func givesUp() async {
            let sleeps = SleepRecorder()
            let client = FakeScrobbleClient { call, _ in
                if call == .scrobble("bad") { throw Self.temporary }
                return nil
            }
            let queue = makeQueue(client, sleeps: sleeps)
            queue.enqueue(scrobble("bad"), label: "bad")
            queue.enqueue(scrobble("good"), label: "good")

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(client.scrobbled == Array(repeating: "bad", count: 10) + ["good"])
            #expect(sleeps.seconds == [1, 2, 4, 8, 16, 32, 64, 128, 256])
        }

        @Test("the delay doubles, unless the server asked for a time (2 minutes at most)")
        func delays() {
            #expect([1, 2, 3, 4, 10].map { ScrobbleQueue.delay(afterAttempt: $0) }
                == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(512)])
            #expect(ScrobbleQueue.delay(afterAttempt: 5, retryAfter: 3) == .seconds(3))
            #expect(ScrobbleQueue.delay(afterAttempt: 1, retryAfter: 7.2) == .seconds(8))
            #expect(ScrobbleQueue.delay(afterAttempt: 1, retryAfter: 100_000) == .seconds(120))
            #expect(ScrobbleQueue.delay(afterAttempt: 3, retryAfter: 0) == .seconds(4))
        }

        @Test("a retry waits as long as the server asked for, instead of the backoff")
        func retryAfter() async {
            let sleeps = SleepRecorder()
            let client = FakeScrobbleClient { _, index in
                switch index {
                case 0: throw ScrobbleError(.temporary, "HTTP 429", retryAfter: 90)
                case 1: throw ScrobbleError(.temporary, "HTTP 429", retryAfter: 1_000_000)
                case 2: throw Self.temporary
                default: return nil
                }
            }
            let queue = makeQueue(client, sleeps: sleeps)
            queue.enqueue(scrobble("1"), label: "1")

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(sleeps.seconds == [90, 120, 4])
        }

        @Test("a now playing update that is outdated when it has to be repeated is dropped; a wait the server asked for is kept first")
        func outdatedNotRepeated() async {
            func run(retryAfter: TimeInterval?) async -> (calls: [FakeScrobbleClient.Call], sleeps: [Int]) {
                let sleeps = SleepRecorder()
                let client = FakeScrobbleClient { call, _ in
                    if call == .nowPlaying("first") { throw ScrobbleError(.temporary, "HTTP 503", retryAfter: retryAfter) }
                    return nil
                }
                let queue = makeQueue(client, sleeps: sleeps)
                queue.enqueue(.nowPlaying(ScrobbleTestData.track(title: "first")), label: "np1")
                queue.enqueue(.nowPlaying(ScrobbleTestData.track(title: "second")), label: "np2")   // the track was switched
                _ = await waitUntil { queue.pendingCount == 0 }
                return (client.calls, sleeps.seconds)
            }

            let plain = await run(retryAfter: nil)
            #expect(plain.calls == [.nowPlaying("first"), .nowPlaying("second")])      // "first" is not repeated
            #expect(plain.sleeps.isEmpty)                                              // and nothing is waited for

            let asked = await run(retryAfter: 30)
            #expect(asked.calls == [.nowPlaying("first"), .nowPlaying("second")])
            #expect(asked.sleeps == [30])                                              // the pause is the service's
        }

        @Test("a now playing update that is still current is repeated")
        func currentRepeated() async {
            let sleeps = SleepRecorder()
            let client = FakeScrobbleClient { _, index in
                if index == 0 { throw ScrobbleError(.temporary, "HTTP 503") }
                return nil
            }
            let queue = makeQueue(client, sleeps: sleeps)
            queue.enqueue(.nowPlaying(ScrobbleTestData.track(title: "first")), label: "np1")
            queue.enqueue(scrobble("other"), label: "scrobble of another track")
            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(client.calls == [.nowPlaying("first"), .nowPlaying("first"), .scrobble("other")])
        }

        @Test("a waiting now playing update is dropped when its track is scrobbled, not when another one is")
        func scrobbleSupersedes() {
            let client = FakeScrobbleClient { _, _ in
                try await Task.sleep(for: .seconds(60))
                return nil
            }
            let queue = makeQueue(client)
            queue.enqueue(scrobble("x"), label: "x")                                               // in flight
            queue.enqueue(.nowPlaying(ScrobbleTestData.track(title: "a")), label: "np a")
            queue.enqueue(scrobble("a"), label: "scrobble a")
            #expect(queue.pendingCount == 2)                                                       // x, scrobble a
            queue.enqueue(.nowPlaying(ScrobbleTestData.track(title: "b")), label: "np b")
            queue.enqueue(scrobble("c"), label: "scrobble c")
            #expect(queue.pendingCount == 4)                                                       // np b stays
            queue.cancelAll()
        }

        @Test("a clearing is dropped by a later update, and a scrobble is never dropped")
        func supersedeRules() {
            let track = ScrobbleTestData.track()
            let scrobbled = ScrobbleQueue.Call.scrobble(track)
            #expect(ScrobbleQueue.Call.clearNowPlaying.isSuperseded(by: .nowPlaying(track)))
            #expect(ScrobbleQueue.Call.clearNowPlaying.isSuperseded(by: .clearNowPlaying))
            #expect(!ScrobbleQueue.Call.clearNowPlaying.isSuperseded(by: scrobbled))
            #expect(ScrobbleQueue.Call.nowPlaying(track).isSuperseded(by: .clearNowPlaying))
            #expect(ScrobbleQueue.Call.nowPlaying(track).isSuperseded(by: scrobbled))
            for call in [scrobbled, .authenticate, .nowPlaying(track), .clearNowPlaying] {
                #expect(!scrobbled.isSuperseded(by: call))
                #expect(!ScrobbleQueue.Call.authenticate.isSuperseded(by: call))
            }
        }

        @Test("a request that is refused for itself is dropped without retries")
        func rejected() async {
            let sleeps = SleepRecorder()
            let client = FakeScrobbleClient { call, _ in
                if call == .scrobble("bad") { throw ScrobbleError(.rejected, "bad parameters") }
                return nil
            }
            var failures: [ScrobbleError] = []
            let queue = makeQueue(client, sleeps: sleeps, onFailure: { failures.append($0) })
            queue.enqueue(scrobble("bad"), label: "bad")
            queue.enqueue(scrobble("good"), label: "good")

            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(client.scrobbled == ["bad", "good"])
            #expect(sleeps.seconds.isEmpty)
            #expect(failures == [ScrobbleError(.rejected, "bad parameters")])
        }

        @Test("refused credentials end everything at once; the next call tries again")
        func authenticationFailure() async {
            let sleeps = SleepRecorder()
            let refuse = ScrobbleCounter()
            let client = FakeScrobbleClient { _, _ in
                if refuse.next() == 1 { throw ScrobbleError(.authentication, "wrong password") }
                return nil
            }
            var failures: [ScrobbleError] = []
            let queue = makeQueue(client, sleeps: sleeps, onFailure: { failures.append($0) })
            queue.enqueue(scrobble("1"), label: "1")
            queue.enqueue(scrobble("2"), label: "2")
            queue.enqueue(scrobble("3"), label: "3")

            #expect(await waitUntil { !failures.isEmpty && queue.pendingCount == 0 })
            #expect(failures == [ScrobbleError(.authentication, "wrong password")])
            #expect(sleeps.seconds.isEmpty)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(client.calls == [.scrobble("1")])         // 2 and 3 were dropped without being sent

            queue.enqueue(scrobble("4"), label: "4")
            #expect(await waitUntil { client.scrobbled == ["1", "4"] })
        }

        @Test("cancelling forgets everything pending, also what is being sent")
        func cancelAll() async {
            let client = FakeScrobbleClient { _, _ in
                try await Task.sleep(for: .seconds(60))
                return nil
            }
            var delivered = 0
            let queue = makeQueue(client, onDelivered: { _ in delivered += 1 })
            queue.enqueue(scrobble("1"), label: "1")
            queue.enqueue(scrobble("2"), label: "2")
            #expect(await waitUntil { client.calls.count == 1 })

            queue.cancelAll()
            #expect(queue.pendingCount == 0)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(client.calls.count == 1 && delivered == 0)

            // It is usable again afterwards.
            let fresh = FakeScrobbleClient()
            let other = makeQueue(fresh)
            other.enqueue(scrobble("3"), label: "3")
            #expect(await waitUntil { other.pendingCount == 0 })
        }

        @Test("cancelling during a retry wait sends nothing more")
        func cancelDuringBackoff() async {
            let client = FakeScrobbleClient { _, _ in throw Self.temporary }
            let blocked = BlockingSleep()
            let queue = ScrobbleQueue(name: "test", client: client, sleep: blocked.sleep,
                                      onDelivered: { _ in }, onFailure: { _ in })
            queue.enqueue(scrobble("1"), label: "1")
            #expect(await waitUntil { blocked.waiting })

            queue.cancelAll()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(client.calls.count == 1)
            #expect(queue.pendingCount == 0)
        }

        @Test("a now playing update waiting behind others is replaced by a newer one; the one being sent stays")
        func nowPlayingReplaced() {
            let client = FakeScrobbleClient { _, _ in
                try await Task.sleep(for: .seconds(60))
                return nil
            }
            let queue = makeQueue(client)
            let first = ScrobbleTestData.track(title: "first")
            queue.enqueue(.nowPlaying(first), label: "np1")
            queue.enqueue(.nowPlaying(ScrobbleTestData.track(title: "second")), label: "np2")
            queue.enqueue(.scrobble(first), label: "scrobble")
            queue.enqueue(.nowPlaying(ScrobbleTestData.track(title: "third")), label: "np3")
            #expect(queue.pendingCount == 3)      // np1 (in flight), scrobble, np3
            queue.cancelAll()
        }

        @Test("clearing now playing replaces the now playing updates waiting, and a new update replaces a waiting clearing")
        func clearingReplaces() {
            let client = FakeScrobbleClient { _, _ in
                try await Task.sleep(for: .seconds(60))
                return nil
            }
            let queue = makeQueue(client)
            let track = ScrobbleTestData.track()
            queue.enqueue(.scrobble(track), label: "scrobble")               // in flight
            queue.enqueue(.nowPlaying(track), label: "np")
            queue.enqueue(.clearNowPlaying, label: "clear")
            #expect(queue.pendingCount == 2)                                 // scrobble, clear: np is stale
            queue.enqueue(.nowPlaying(track), label: "np again")
            #expect(queue.pendingCount == 2)                                 // scrobble, np again: clear is stale
            queue.cancelAll()
        }

        @Test("clearing goes through the client, after the scrobble before it")
        func clearing() async {
            let client = FakeScrobbleClient()
            let queue = makeQueue(client)
            queue.enqueue(scrobble("1"), label: "1")
            queue.enqueue(.clearNowPlaying, label: "clear")
            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(client.calls == [.scrobble("1"), .clearNowPlaying])
        }
    }

    // MARK: - Service

    @MainActor @Suite("Scrobbling service")
    struct ScrobblingServiceTests {
        private struct Env {
            let paths: AppPaths
            let config: ConfigStore
            let transport: StubTransport
            let sleeps: SleepRecorder
            let service: ScrobblingService
        }

        private static func listenBrainz(_ name: String, host: String = "lb.example.org", secret: String = "TOK",
                                         nowPlaying: Bool = true, enabled: Bool = true) -> ScrobbleServiceConfig {
            ScrobbleServiceConfig(name: name, type: .listenbrainz, endpoint: "https://\(host)", secret: secret,
                                  submitNowPlaying: nowPlaying, enabled: enabled)
        }

        private static let audioscrobbler = ScrobbleServiceConfig(
            name: "AS", type: .audioscrobbler, endpoint: "https://as.example.org", username: "bob", secret: "pw")

        /// Healthy servers: ListenBrainz validates the token and takes listens, Audioscrobbler shakes hands and takes calls.
        private nonisolated static func healthyAnswer(for request: URLRequest) -> StubTransport.Answer {
            if request.url?.path == "/1/validate-token" { return ScrobbleAnswer.tokenValid(user: "alice") }
            if request.url?.path == "/1/submit-listens" { return ScrobbleAnswer.accepted }
            if request.httpMethod == "POST" { return ScrobbleAnswer.ok }
            return ScrobbleAnswer.handshake()
        }

        private func makeEnv(_ services: [ScrobbleServiceConfig] = [], transport: StubTransport? = nil) throws -> Env {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            config.update { $0.scrobbling = services.sorted(by: ScrobbleServiceConfig.isOrderedBefore) }
            let transport = transport ?? StubTransport { request, _ in Self.healthyAnswer(for: request) }
            let sleeps = SleepRecorder()
            let service = ScrobblingService(configStore: config, transport: transport, sleep: sleeps.sleep)
            return Env(paths: paths, config: config, transport: transport, sleeps: sleeps, service: service)
        }

        private func paths(_ transport: StubTransport) -> [String] {
            transport.requests.map { "\($0.url?.host ?? "")\($0.url?.path ?? "")" }
        }

        @Test("without services nothing is sent")
        func idle() async throws {
            let env = try makeEnv()
            env.service.trackDidStart(ScrobbleTestData.track())
            env.service.trackDidEnd(ScrobbleTestData.track(), playedSeconds: 200)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.isEmpty)
            #expect(env.service.services.isEmpty)
        }

        @Test("enabled services are authenticated at the start, disabled ones are left alone")
        func authenticatesAtStart() async throws {
            let env = try makeEnv([Self.listenBrainz("on"), Self.listenBrainz("off", host: "off.example.org", enabled: false)])
            let on = try #require(env.service.services.first { $0.name == "on" })
            #expect(await waitUntil { env.transport.requests.count == 1 && env.service.status(of: on.id).isOK })
            try? await Task.sleep(for: .milliseconds(30))
            #expect(paths(env.transport) == ["lb.example.org/1/validate-token"])
            let request = env.transport.requests[0]
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token TOK")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent)
            #expect(env.service.statuses.values.allSatisfy { $0.error == nil })
        }

        @Test("an Audioscrobbler service shakes hands, then sends now playing and scrobbles to the URLs it got")
        func audioscrobblerFlow() async throws {
            let env = try makeEnv([Self.audioscrobbler])
            env.service.trackDidStart(ScrobbleTestData.track(title: "T"))
            // (A now playing update that is still waiting when its track ends is not sent at all.)
            #expect(await waitUntil { env.transport.requests.count == 2 })
            env.service.trackDidEnd(ScrobbleTestData.track(title: "T"), playedSeconds: 200)
            #expect(await waitUntil { env.transport.requests.count == 3 })
            #expect(env.transport.requests.map { $0.url?.host } == ["as.example.org", "np.example.org", "sub.example.org"])
            #expect(StubTransport.form(of: env.transport.requests[1])["t"] == "T")
            #expect(StubTransport.form(of: env.transport.requests[2])["t[0]"] == "T")
        }

        @Test("a service that refuses the credentials is marked, and the mark goes away with the next success")
        func errorMark() async throws {
            let tokenOK = ScrobbleCounter()
            let transport = StubTransport { request, _ in
                if request.url?.path == "/1/validate-token" {
                    return tokenOK.next() == 1 ? ScrobbleAnswer.tokenInvalid : ScrobbleAnswer.tokenValid()
                }
                return ScrobbleAnswer.accepted
            }
            let env = try makeEnv([Self.listenBrainz("lb")], transport: transport)
            let id = env.service.services[0].id
            #expect(await waitUntil { env.service.status(of: id).error != nil })
            #expect(env.service.status(of: id).lastScrobble == nil && !env.service.status(of: id).isOK)

            // The next track is a new try: this time the call goes through.
            env.service.trackDidEnd(ScrobbleTestData.track(), playedSeconds: 200)
            #expect(await waitUntil { env.service.status(of: id).lastScrobble != nil })
            #expect(env.service.status(of: id).error == nil && env.service.status(of: id).isOK)
            #expect(abs(try #require(env.service.status(of: id).lastScrobble).timeIntervalSinceNow) < 5)
        }

        @Test("temporary trouble is retried, marks the service meanwhile, and doesn't need the user")
        func temporaryTrouble() async throws {
            let transport = StubTransport { request, index in
                if request.url?.path == "/1/validate-token" { return ScrobbleAnswer.tokenValid() }
                return index < 3 ? ScrobbleAnswer.serverError : ScrobbleAnswer.accepted
            }
            let env = try makeEnv([Self.listenBrainz("lb")], transport: transport)
            let id = env.service.services[0].id
            env.service.trackDidEnd(ScrobbleTestData.track(), playedSeconds: 200)
            #expect(await waitUntil { env.service.status(of: id).lastScrobble != nil })
            #expect(env.service.status(of: id).error == nil)
            #expect(env.sleeps.seconds == [1, 2])
        }

        @Test("now playing goes to the services that take it, scrobbles to all enabled ones")
        func routing() async throws {
            let env = try makeEnv([
                Self.listenBrainz("a", host: "a.example.org"),
                Self.listenBrainz("b", host: "b.example.org", nowPlaying: false),
                Self.listenBrainz("c", host: "c.example.org", enabled: false),
            ])
            #expect(await waitUntil { env.transport.requests.count == 2 })       // the two authentications
            env.service.trackDidStart(ScrobbleTestData.track())
            env.service.trackDidEnd(ScrobbleTestData.track(), playedSeconds: 200)
            #expect(await waitUntil { env.transport.requests.count == 5 })
            try? await Task.sleep(for: .milliseconds(30))

            let submits = env.transport.requests.filter { $0.url?.path == "/1/submit-listens" }
            let sent = submits.map { "\($0.url?.host ?? ""):\(StubTransport.json(of: $0)["listen_type"] as? String ?? "")" }
            #expect(Set(sent) == ["a.example.org:playing_now", "a.example.org:single", "b.example.org:single"])
            #expect(sent.count == 3)
        }

        @Test("when playback stops, ListenBrainz is told to clear now playing, Audioscrobbler and services without now playing are not")
        func stopClears() async throws {
            let env = try makeEnv([
                Self.listenBrainz("a", host: "a.example.org"),
                Self.listenBrainz("b", host: "b.example.org", nowPlaying: false),
                Self.listenBrainz("c", host: "c.example.org", enabled: false),
                Self.audioscrobbler,
            ])
            #expect(await waitUntil { env.transport.requests.count == 3 })       // the three authentications
            env.service.trackDidStart(ScrobbleTestData.track())
            env.service.playbackDidStop()
            #expect(await waitUntil { env.transport.requests.contains { $0.url?.path == "/1/playing-now/delete" } })
            try? await Task.sleep(for: .milliseconds(30))

            let clears = env.transport.requests.filter { $0.url?.path == "/1/playing-now/delete" }
            #expect(clears.map { $0.url?.host } == ["a.example.org"])
            #expect(clears[0].value(forHTTPHeaderField: "Authorization") == "Token TOK")
            // Audioscrobbler only got its handshake and the now playing update.
            #expect(env.transport.requests.filter { $0.url?.host?.hasSuffix("example.org") == true && $0.url?.host == "as.example.org" }.count == 1)
        }

        @Test("tracks are scrobbled by the rule, and tracks without tags are not reported at all")
        func rule() async throws {
            let env = try makeEnv([Self.listenBrainz("lb")])
            #expect(await waitUntil { env.transport.requests.count == 1 })
            let started = Date(timeIntervalSince1970: 1_700_000_123)
            func track(_ title: String, duration: TimeInterval = 200, artist: String = "Artist") -> PlayedTrack {
                ScrobbleTestData.track(artist: artist, title: title, duration: duration, startedAt: started)
            }
            env.service.trackDidEnd(track("short of half"), playedSeconds: 99)
            env.service.trackDidEnd(track("too short to scrobble", duration: 29), playedSeconds: 29)
            env.service.trackDidEnd(track("no duration", duration: 0), playedSeconds: 500)
            env.service.trackDidEnd(track("no artist", artist: "  "), playedSeconds: 200)
            env.service.trackDidEnd(track("untagged", artist: TagFallback.artist), playedSeconds: 200)
            env.service.trackDidEnd(track("half"), playedSeconds: 100)
            env.service.trackDidEnd(track("long track", duration: 1000), playedSeconds: 240)
            env.service.trackDidEnd(track("long track, not yet", duration: 1000), playedSeconds: 239)
            env.service.trackDidStart(track("untagged", artist: TagFallback.artist))

            #expect(await waitUntil { env.transport.requests.count == 3 })
            try? await Task.sleep(for: .milliseconds(30))
            let titles = env.transport.requests.dropFirst().compactMap { request -> String? in
                let payload = StubTransport.json(of: request)["payload"] as? [[String: Any]]
                return (payload?.first?["track_metadata"] as? [String: Any])?["track_name"] as? String
            }
            #expect(titles == ["half", "long track"])
            let first = StubTransport.json(of: env.transport.requests[1])
            #expect(((first["payload"] as? [[String: Any]])?.first?["listened_at"] as? Int) == 1_700_000_123)
        }

        @Test("adding, editing and removing is kept in the config, sorted, with the secret obfuscated")
        func editing() async throws {
            let env = try makeEnv()
            env.service.add(Self.listenBrainz("b", host: "b.example.org", secret: "SECRET-B"))
            env.service.add(Self.listenBrainz("A", host: "a.example.org", secret: "SECRET-A"))
            #expect(env.service.services.map(\.name) == ["A", "b"])
            #expect(env.config.config.scrobbling == env.service.services)

            var edited = env.service.services[0]
            edited.name = "z"
            env.service.update(edited)
            #expect(env.service.services.map(\.name) == ["b", "z"])

            env.config.flush()
            let saved = try String(contentsOf: env.paths.configURL, encoding: .utf8)
            #expect(!saved.contains("SECRET-A") && !saved.contains("SECRET-B"))
            #expect(saved.contains(Obfuscation.obfuscated("SECRET-A")))

            env.service.remove(edited.id)
            #expect(env.service.services.map(\.name) == ["b"])
            #expect(env.config.config.scrobbling.map(\.name) == ["b"])
        }

        @Test("a new or changed connection is authenticated; a change of the name alone is not")
        func reauthentication() async throws {
            let env = try makeEnv()
            env.service.add(Self.listenBrainz("lb"))
            #expect(await waitUntil { env.transport.requests.count == 1 })

            var service = env.service.services[0]
            service.name = "renamed"
            service.submitNowPlaying = false
            env.service.update(service)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.count == 1)

            service.secret = "OTHER"
            env.service.update(service)
            #expect(await waitUntil { env.transport.requests.count == 2 })
            #expect(env.transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Token OTHER")
        }

        @Test("editing a service that was marked starts it fresh")
        func editingClearsTheMark() async throws {
            let transport = StubTransport { request, _ in
                request.value(forHTTPHeaderField: "Authorization") == "Token GOOD"
                    ? (request.url?.path == "/1/validate-token" ? ScrobbleAnswer.tokenValid() : ScrobbleAnswer.accepted)
                    : ScrobbleAnswer.lbError(401, "Invalid authorization token.")
            }
            let env = try makeEnv([Self.listenBrainz("lb", secret: "BAD")], transport: transport)
            let id = env.service.services[0].id
            #expect(await waitUntil { env.service.status(of: id).error != nil })

            var fixed = env.service.services[0]
            fixed.secret = "GOOD"
            env.service.update(fixed)
            #expect(env.service.status(of: id).error == nil)
            env.service.trackDidEnd(ScrobbleTestData.track(), playedSeconds: 200)
            #expect(await waitUntil { env.service.status(of: id).lastScrobble != nil })
            #expect(env.service.status(of: id).error == nil)
        }

        @Test("a disabled service gets nothing, and switching it on authenticates it")
        func enabling() async throws {
            let env = try makeEnv([Self.listenBrainz("lb")])
            let id = env.service.services[0].id
            #expect(await waitUntil { env.transport.requests.count == 1 })

            env.service.setEnabled(false, for: id)
            env.service.trackDidStart(ScrobbleTestData.track())
            env.service.trackDidEnd(ScrobbleTestData.track(), playedSeconds: 200)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(env.transport.requests.count == 1)
            #expect(!env.config.config.scrobbling[0].enabled)

            env.service.setEnabled(true, for: id)
            #expect(await waitUntil { env.transport.requests.count == 2 })
            #expect(paths(env.transport).last == "lb.example.org/1/validate-token")
        }

        @Test("removing a service drops what is pending for it")
        func removing() async throws {
            let transport = StubTransport { request, _ in
                if request.url?.path == "/1/validate-token" { return ScrobbleAnswer.tokenValid() }
                try await Task.sleep(for: .seconds(60))
                return ScrobbleAnswer.accepted
            }
            let env = try makeEnv([Self.listenBrainz("lb")], transport: transport)
            let id = env.service.services[0].id
            env.service.trackDidStart(ScrobbleTestData.track(title: "1"))
            env.service.trackDidEnd(ScrobbleTestData.track(title: "1"), playedSeconds: 200)
            #expect(await waitUntil { transport.requests.count == 2 })

            env.service.remove(id)
            env.service.trackDidEnd(ScrobbleTestData.track(title: "2"), playedSeconds: 200)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(transport.requests.count == 2)
            #expect(env.service.status(of: id) == ScrobblingService.Status())
        }

        @Test("a service that is down doesn't hold up the others")
        func independent() async throws {
            let transport = StubTransport { request, _ in
                if request.url?.host == "down.example.org" { return ScrobbleAnswer.serverError }
                return request.url?.path == "/1/validate-token" ? ScrobbleAnswer.tokenValid() : ScrobbleAnswer.accepted
            }
            let env = try makeEnv([Self.listenBrainz("down", host: "down.example.org"),
                                   Self.listenBrainz("up", host: "up.example.org")], transport: transport)
            env.service.trackDidEnd(ScrobbleTestData.track(), playedSeconds: 200)

            let up = try #require(env.service.services.first { $0.name == "up" })
            let down = try #require(env.service.services.first { $0.name == "down" })
            #expect(await waitUntil { env.service.status(of: up.id).lastScrobble != nil })
            #expect(await waitUntil { env.service.status(of: down.id).error != nil })
            #expect(env.service.status(of: up.id).error == nil)
            #expect(env.service.status(of: down.id).lastScrobble == nil)
        }

        @Test("testing a connection says what came of it, and touches nothing")
        func testing() async throws {
            let env = try makeEnv()
            var candidate = Self.listenBrainz("unsaved")
            #expect(await env.service.test(candidate) == .success("Success: connected as alice."))
            #expect(await env.service.test(Self.audioscrobbler) == .success("Success: connected as bob."))

            var anonymous = Self.audioscrobbler
            anonymous.username = ""
            #expect(await env.service.test(anonymous) == .success("Success: the service accepted the connection."))

            candidate.endpoint = "nope"
            #expect(await env.service.test(candidate) == .failure("The endpoint isn't an http:// or https:// URL."))

            #expect(env.service.services.isEmpty && env.service.statuses.isEmpty)
            #expect(env.config.config.scrobbling.isEmpty)
        }

        @Test("a test that fails gives the reason, as a sentence")
        func testFailing() async throws {
            let transport = StubTransport(always: ScrobbleAnswer.text("BADAUTH\n"))
            let env = try makeEnv(transport: transport)
            guard case .failure(let message) = await env.service.test(Self.audioscrobbler) else {
                Issue.record("should fail")
                return
            }
            #expect(message.hasPrefix("The server doesn't accept the username and password"))

            let offline = try makeEnv(transport: StubTransport { _, _ in throw URLError(.notConnectedToInternet) })
            guard case .failure(let reason) = await offline.service.test(Self.listenBrainz("lb")) else {
                Issue.record("should fail")
                return
            }
            #expect(!reason.isEmpty)
        }
    }

    // MARK: - Last.fm leftovers

    @MainActor @Suite("Last.fm removal")
    struct LegacyLastFMTests {
        @Test("a Last.fm login in the raw config is recognized, with the account name if there is one")
        func detection() {
            func login(_ json: String) -> LegacyLastFM.Login? { LegacyLastFM.login(inConfig: Data(json.utf8)) }
            #expect(login(#"{"integrations": {"lastfm": {"session": "abc", "username": "bob"}}}"#) == .init(username: "bob"))
            #expect(login(#"{"integrations": {"lastfm": {"session": "abc", "username": "  "}}}"#) == .init(username: nil))
            #expect(login(#"{"integrations": {"lastfm": {"session": "abc"}}}"#) == .init(username: nil))
            #expect(login(#"{"integrations": {"lastfm": {"session": "", "username": "bob"}}}"#) == nil)
            #expect(login(#"{"integrations": {"lastfm": {}}}"#) == nil)
            #expect(login(#"{"integrations": {"lrclib": {"enabled": true}}}"#) == nil)
            #expect(login(#"{"integrations": 5}"#) == nil)
            #expect(login("{}") == nil)
            #expect(login("nope") == nil)
        }

        @Test("the suggested service is Audioscrobbler on Last.fm's server, with the account name and no password")
        func suggestion() {
            let service = LegacyLastFM.suggestedService(for: .init(username: "bob"))
            #expect(service.name == "Last.fm" && service.type == .audioscrobbler)
            #expect(service.endpoint == ScrobbleServiceConfig.lastFMEndpoint)
            #expect(ScrobbleServiceConfig.normalizedEndpoint(service.endpoint) == service.endpoint)
            #expect(service.username == "bob" && service.secret.isEmpty)
            #expect(service.problem(among: []) != nil)          // the password is still to be entered
            var filled = service
            filled.secret = "pw"
            #expect(filled.problem(among: []) == nil)

            #expect(LegacyLastFM.suggestedService(for: .init(username: nil)).username.isEmpty)
        }

        @Test("loading a config with a login removes it from the file and notices it once, with the account name")
        func loading() throws {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            try dir.write("work/config.json", Data(#"""
            {"integrations": {"lastfm": {"session": "SESSIONKEY", "username": "bob"}, "lrclib": {"enabled": true}}}
            """#.utf8))

            let store = ConfigStore(paths: paths, saveDelay: .seconds(60))
            #expect(store.config.integrations.lrclib.enabled)         // the rest of the config stays
            #expect(store.takeLegacyLastFMNotice() == .init(username: "bob"))
            #expect(store.takeLegacyLastFMNotice() == nil)

            let saved = try String(contentsOf: paths.configURL, encoding: .utf8)
            #expect(!saved.contains("SESSIONKEY") && !saved.contains("lastfm"))

            // The next start doesn't see it any more.
            #expect(ConfigStore(paths: paths, saveDelay: .seconds(60)).takeLegacyLastFMNotice() == nil)
        }

        @Test("nothing to announce for a fresh start or a config without a login")
        func nothingToSay() throws {
            let dir = try TempDir()
            #expect(ConfigStore(paths: AppPaths(workDir: dir.path("fresh")), saveDelay: .seconds(60)).takeLegacyLastFMNotice() == nil)

            let other = try TempDir()
            try other.write("work/config.json", Data(#"{"integrations": {"lastfm": {"session": "", "username": ""}}}"#.utf8))
            #expect(ConfigStore(paths: AppPaths(workDir: other.path("work")), saveDelay: .seconds(60)).takeLegacyLastFMNotice() == nil)
        }

        @Test("a login of the previous version is noted by the migration")
        func noted() throws {
            let store = ConfigStore(paths: AppPaths(workDir: try TempDir().path("work")), saveDelay: .seconds(60))
            #expect(store.takeLegacyLastFMNotice() == nil)
            store.noteLegacyLastFM(username: " alice ")
            #expect(store.takeLegacyLastFMNotice() == .init(username: "alice"))
            #expect(store.takeLegacyLastFMNotice() == nil)
        }
    }
}
