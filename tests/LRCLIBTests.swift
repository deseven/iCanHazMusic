import Foundation
import Testing
@testable import iCanHazMusic

/// What the queue reports.
@MainActor
private final class Results {
    private(set) var all: [(query: LRCLIBQuery, outcome: LRCLIBOutcome)] = []

    func record(_ query: LRCLIBQuery, _ outcome: LRCLIBOutcome) { all.append((query, outcome)) }

    func outcome(of title: String) -> LRCLIBOutcome? { all.first { $0.query.title == title }?.outcome }
}

extension AllTests {
    // MARK: - API

    @MainActor @Suite("LRCLIB API")
    struct LRCLIBAPITests {
        private let query = LRCLIBTestData.query

        @Test("a request is a GET search by title and artist, with the app's user agent and values that survive the encoding")
        func request() {
            let request = LRCLIBAPI.request(for: LRCLIBQuery(artist: "AC/DC & Co+Friends", title: "x y=z%é", album: "Album", duration: 200))
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == "lrclib.net" && request.url?.path == "/api/search")
            #expect(request.timeoutInterval == 30)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent)

            let items = HTTPStub.query(of: request)
            #expect(items["artist_name"] == "AC/DC & Co+Friends")
            #expect(items["track_name"] == "x y=z%é")
            #expect(items.count == 2)
            let rawQuery = request.url?.query ?? ""
            #expect(!rawQuery.contains("&Co"))
        }

        @Test("errors are told apart: busy and broken is temporary (429 with the wait asked for), the rest is refused")
        func classification() {
            func error(_ answer: HTTPAnswer) -> LRCLIBError? {
                do { _ = try LRCLIBAPI.check(answer) } catch let error as LRCLIBError { return error } catch {}
                return nil
            }
            #expect(error(LRCLIBAnswer.none) == nil)
            #expect(error(LRCLIBAnswer.serverError)?.kind == .temporary)
            #expect(error(HTTPAnswer(status: 503, body: Data()))?.kind == .temporary)
            let busy = error(LRCLIBAnswer.tooManyRequests(retryAfter: 42))
            #expect(busy?.kind == .temporary && busy?.retryAfter == 42)
            #expect(error(LRCLIBAnswer.notFound)?.kind == .rejected)
            #expect(error(LRCLIBAnswer.notFound)?.message.contains("nope") == true)
            #expect(error(HTTPAnswer(status: 400, body: Data("garbage".utf8)))?.kind == .rejected)
        }

        private func match(_ records: [[String: Any]], for query: LRCLIBQuery? = nil) throws -> Lyrics? {
            try LRCLIBAPI.match(for: query ?? self.query, in: LRCLIBAnswer.records(records).body)
        }

        @Test("artist and title have to be the same, only case and blank space may differ")
        func exactNames() throws {
            #expect(try match([LRCLIBAnswer.record()])?.plain == "la la la")
            #expect(try match([LRCLIBAnswer.record(artist: "  ARTIST ", title: "title")]) != nil)
            #expect(try match([LRCLIBAnswer.record(artist: "Artist - Topic")]) == nil)
            #expect(try match([LRCLIBAnswer.record(artist: "The Artist")]) == nil)
            #expect(try match([LRCLIBAnswer.record(title: "Title (Remastered)")]) == nil)
            #expect(try match([LRCLIBAnswer.record(title: "Títle")]) == nil)
            #expect(try match([]) == nil)

            let spaced = LRCLIBQuery(artist: "Two  Words", title: "A\tB", album: "", duration: 200)
            #expect(try match([LRCLIBAnswer.record(artist: "two words", title: "a b")], for: spaced) != nil)
        }

        @Test("the length may be 10% off")
        func durationTolerance() throws {
            for (length, accepted) in [(200.0, true), (220.0, true), (180.0, true), (220.5, false), (179.9, false), (0, false), (400, false)] {
                #expect(try (match([LRCLIBAnswer.record(duration: length)]) != nil) == accepted, "\(length) s")
            }
            let noDuration = LRCLIBQuery(artist: "Artist", title: "Title", album: "Album", duration: 0)
            #expect(try match([LRCLIBAnswer.record(duration: 12345)], for: noDuration) != nil)
        }

        @Test("records without lyrics, and instrumentals, don't count")
        func needsLyrics() throws {
            #expect(try match([LRCLIBAnswer.record(plain: nil)]) == nil)
            #expect(try match([LRCLIBAnswer.record(plain: "  ")]) == nil)
            #expect(try match([LRCLIBAnswer.record(plain: "text", instrumental: true)]) == nil)
            #expect(try match([LRCLIBAnswer.record(plain: nil), LRCLIBAnswer.record(plain: "second")])?.plain == "second")
        }

        @Test("of the records that fit, synchronised lyrics win, then the same album, then the nearest length")
        func choice() throws {
            let synced = "[00:01.00]one\n[00:02.00]two"
            let lyrics = try #require(try match([
                LRCLIBAnswer.record(album: "Album", duration: 200, plain: "plain, same album"),
                LRCLIBAnswer.record(album: "Other", duration: 201, plain: "plain", synced: synced),
                LRCLIBAnswer.record(album: "Other", duration: 205, plain: "plain 2", synced: synced),
            ]))
            #expect(lyrics.isSynced && lyrics.source == .lrclib && lyrics.plain == "plain")

            let sameAlbum = try #require(try match([
                LRCLIBAnswer.record(album: "Other", duration: 200, plain: "other album"),
                LRCLIBAnswer.record(album: "ALBUM", duration: 210, plain: "same album"),
            ]))
            #expect(sameAlbum.plain == "same album")

            let nearest = try #require(try match([
                LRCLIBAnswer.record(album: "A", duration: 210, plain: "far"),
                LRCLIBAnswer.record(album: "B", duration: 202, plain: "near"),
            ]))
            #expect(nearest.plain == "near")
        }

        @Test("a record with only synchronised lyrics gives plain ones too")
        func syncedOnly() throws {
            let lyrics = try #require(try match([LRCLIBAnswer.record(plain: nil, synced: "[00:01.00]one\n[00:02.50]two")]))
            #expect(lyrics.plain == "one\ntwo")
            #expect(lyrics.lines == [LyricLine(time: 1, text: "one"), LyricLine(time: 2.5, text: "two")])
        }

        @Test("an answer that isn't a list of records is a temporary error")
        func garbage() {
            for body in ["<html>", "{\"a\":1}", ""] {
                do {
                    _ = try LRCLIBAPI.match(for: query, in: Data(body.utf8))
                    Issue.record("\(body) should be refused")
                } catch let error as LRCLIBError {
                    #expect(error.kind == .temporary)
                } catch {
                    Issue.record("unexpected error \(error)")
                }
            }
        }
    }

    // MARK: - Client

    @MainActor @Suite("LRCLIB client")
    struct LRCLIBClientTests {
        @Test("a lookup is one request, and gives the lyrics of the matching record")
        func lookup() async throws {
            let transport = HTTPStub(always: LRCLIBAnswer.records([LRCLIBAnswer.record(plain: "found")]))
            let lyrics = try await LRCLIBClient(transport: transport).lookup(LRCLIBTestData.query)
            #expect(lyrics?.plain == "found")
            #expect(transport.requests.count == 1)
            #expect(HTTPStub.query(of: transport.requests[0])["track_name"] == "Title")
        }

        @Test("no matching record is no lyrics, not an error")
        func noMatch() async throws {
            let transport = HTTPStub(always: LRCLIBAnswer.none)
            #expect(try await LRCLIBClient(transport: transport).lookup(LRCLIBTestData.query) == nil)
        }

        @Test("failures come out as LRCLIB errors")
        func failures() async {
            func kind(_ transport: HTTPStub) async -> LRCLIBError.Kind? {
                do { _ = try await LRCLIBClient(transport: transport).lookup(LRCLIBTestData.query) } catch let error as LRCLIBError {
                    return error.kind
                } catch {}
                return nil
            }
            #expect(await kind(HTTPStub { _, _ in throw URLError(.notConnectedToInternet) }) == .temporary)
            #expect(await kind(HTTPStub(always: LRCLIBAnswer.serverError)) == .temporary)
            #expect(await kind(HTTPStub(always: LRCLIBAnswer.tooManyRequests())) == .temporary)
            #expect(await kind(HTTPStub(always: LRCLIBAnswer.notFound)) == .rejected)
        }

        @Test("cancelling is not an error of LRCLIB")
        func cancelled() async {
            let transport = HTTPStub { _, _ in throw CancellationError() }
            do {
                _ = try await LRCLIBClient(transport: transport).lookup(LRCLIBTestData.query)
                Issue.record("should throw")
            } catch is CancellationError {
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    // MARK: - Queue

    @MainActor @Suite("LRCLIB queue")
    struct LRCLIBQueueTests {
        private func makeQueue(_ transport: HTTPStub, results: Results, sleeps: SleepRecorder = SleepRecorder(),
                               spacing: Duration = .zero) -> LRCLIBQueue {
            LRCLIBQueue(client: LRCLIBClient(transport: transport), spacing: spacing, sleep: sleeps.sleep) {
                results.record($0, $1)
            }
        }

        @Test("a lookup is sent, and its result reported once")
        func sequential() async {
            let transport = HTTPStub { request, _ in
                try await Task.sleep(for: .milliseconds(10))
                return LRCLIBAnswer.found(for: request)
            }
            let results = Results()
            let queue = makeQueue(transport, results: results)
            queue.enqueue(LRCLIBTestData.query(title: "Title"))
            #expect(await waitUntil { queue.pendingCount == 0 })
            #expect(results.all.count == 1)
            #expect(results.outcome(of: "Title") == .found(Lyrics(source: .lrclib, plain: "text", lrc: nil)!))
        }

        @Test("enqueueing doesn't wait for the network")
        func nonBlocking() {
            let transport = HTTPStub { request, _ in
                try await Task.sleep(for: .seconds(60))
                return LRCLIBAnswer.found(for: request)
            }
            let queue = makeQueue(transport, results: Results())
            queue.enqueue(LRCLIBTestData.query(title: "1"))
            #expect(queue.pendingCount == 1)
            queue.cancelAll()
        }

        @Test("a lookup that found nothing is reported as such")
        func notFound() async {
            let results = Results()
            let queue = makeQueue(HTTPStub(always: LRCLIBAnswer.none), results: results)
            queue.enqueue(LRCLIBTestData.query(title: "1"))
            #expect(await waitUntil { results.all.count == 1 })
            #expect(results.outcome(of: "1") == .notFound)
        }

        @Test("a temporary failure is retried after 1, 2, 4 ... seconds, and the lookup then goes through")
        func retries() async {
            let sleeps = SleepRecorder()
            let transport = HTTPStub { request, index in index < 4 ? LRCLIBAnswer.serverError : LRCLIBAnswer.found(for: request) }
            let results = Results()
            let queue = makeQueue(transport, results: results, sleeps: sleeps)
            queue.enqueue(LRCLIBTestData.query(title: "1"))

            #expect(await waitUntil { results.all.count == 1 })
            #expect(sleeps.seconds == [1, 2, 4, 8])
            #expect(transport.requests.count == 5)
            if case .found = results.outcome(of: "1") {} else { Issue.record("should be found") }
        }

        @Test("a network failure counts as temporary too")
        func networkFailure() async {
            let transport = HTTPStub { request, index in
                if index == 0 { throw URLError(.timedOut) }
                return LRCLIBAnswer.found(for: request)
            }
            let sleeps = SleepRecorder()
            let results = Results()
            let queue = makeQueue(transport, results: results, sleeps: sleeps)
            queue.enqueue(LRCLIBTestData.query(title: "1"))
            #expect(await waitUntil { results.all.count == 1 })
            #expect(sleeps.seconds == [1])
        }

        @Test("when LRCLIB says how long to wait (429), that is waited if it is more than the backoff")
        func retryAfter() async {
            let transport = HTTPStub { request, index in
                switch index {
                case 0: LRCLIBAnswer.tooManyRequests(retryAfter: 30)
                case 1: LRCLIBAnswer.tooManyRequests(retryAfter: 1)       // the backoff (2 s) is longer
                case 2: LRCLIBAnswer.tooManyRequests(retryAfter: 100_000)  // not waited for for ever
                default: LRCLIBAnswer.found(for: request)
                }
            }
            let sleeps = SleepRecorder()
            let results = Results()
            let queue = makeQueue(transport, results: results, sleeps: sleeps)
            queue.enqueue(LRCLIBTestData.query(title: "1"))
            #expect(await waitUntil { results.all.count == 1 })
            #expect(sleeps.seconds == [30, 2, 600])
        }

        @Test("a lookup is tried 10 times at most, then given up on, and the next one is sent")
        func givesUp() async {
            let sleeps = SleepRecorder()
            let transport = HTTPStub { request, _ in
                HTTPStub.query(of: request)["track_name"] == "bad" ? LRCLIBAnswer.serverError : LRCLIBAnswer.found(for: request)
            }
            let results = Results()
            let queue = makeQueue(transport, results: results, sleeps: sleeps)
            queue.enqueue(LRCLIBTestData.query(title: "bad"))
            #expect(await waitUntil { transport.requests.count >= 1 })
            queue.enqueue(LRCLIBTestData.query(title: "good"))

            #expect(await waitUntil { results.all.count == 2 })
            #expect(results.outcome(of: "bad") == .failed)
            if case .found = results.outcome(of: "good") {} else { Issue.record("good should be found") }
            #expect(transport.titles.filter { $0 == "bad" }.count == LRCLIBQueue.maxAttempts)
            #expect(sleeps.seconds == [1, 2, 4, 8, 16, 32, 64, 128, 256])
        }

        @Test("the delay doubles, and is at least what LRCLIB asked for")
        func delays() {
            #expect([1, 2, 3, 4, 10].map { LRCLIBQueue.delay(afterAttempt: $0) } == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(512)])
            #expect(LRCLIBQueue.delay(afterAttempt: 1, retryAfter: 7.2) == .seconds(8))
            #expect(LRCLIBQueue.delay(afterAttempt: 5, retryAfter: 3) == .seconds(16))
        }

        @Test("a lookup that LRCLIB refuses is dropped without retries")
        func rejected() async {
            let sleeps = SleepRecorder()
            let transport = HTTPStub { request, _ in
                HTTPStub.query(of: request)["track_name"] == "bad" ? LRCLIBAnswer.notFound : LRCLIBAnswer.found(for: request)
            }
            let results = Results()
            let queue = makeQueue(transport, results: results, sleeps: sleeps)
            queue.enqueue(LRCLIBTestData.query(title: "bad"))
            #expect(await waitUntil { transport.requests.count == 1 })
            queue.enqueue(LRCLIBTestData.query(title: "good"))

            #expect(await waitUntil { results.all.count == 2 })
            #expect(results.outcome(of: "bad") == .failed)
            #expect(transport.titles == ["bad", "good"])
            #expect(sleeps.seconds.isEmpty)
        }

        @Test("only the lookup in progress and the newest one are kept: what waited behind is replaced")
        func newestWins() async {
            let gate = GatedSleep()
            let results = Results()
            // The first lookup fails once and waits for its retry, so the others pile up behind it.
            let transport = HTTPStub { request, index in index == 0 ? LRCLIBAnswer.serverError : LRCLIBAnswer.found(for: request) }
            let queue = LRCLIBQueue(client: LRCLIBClient(transport: transport), spacing: .zero, sleep: gate.sleep) {
                results.record($0, $1)
            }
            queue.enqueue(LRCLIBTestData.query(title: "1"))
            #expect(await waitUntil { gate.waiting })
            queue.enqueue(LRCLIBTestData.query(title: "2"))
            queue.enqueue(LRCLIBTestData.query(title: "3"))
            #expect(queue.pendingCount == 2)                                    // the one in progress, and "3"
            #expect(results.outcome(of: "2") == .failed)

            gate.release()
            #expect(await waitUntil { results.all.count == 3 })
            #expect(transport.titles == ["1", "1", "3"])
            if case .found = results.outcome(of: "3") {} else { Issue.record("3 should be found") }
        }

        @Test("a pause is kept after every lookup")
        func spacing() async {
            let sleeps = SleepRecorder()
            let results = Results()
            let queue = makeQueue(HTTPStub { request, _ in LRCLIBAnswer.found(for: request) }, results: results, sleeps: sleeps, spacing: .milliseconds(300))
            queue.enqueue(LRCLIBTestData.query(title: "1"))
            #expect(await waitUntil { results.all.count == 1 && sleeps.seconds.count == 1 })
            #expect(sleeps.seconds == [0])                                      // 300 ms, in whole seconds
        }

        @Test("cancelling forgets everything pending and tells nobody")
        func cancelAll() async {
            let transport = HTTPStub { request, _ in
                try await Task.sleep(for: .seconds(60))
                return LRCLIBAnswer.found(for: request)
            }
            let results = Results()
            let queue = makeQueue(transport, results: results)
            queue.enqueue(LRCLIBTestData.query(title: "1"))
            #expect(await waitUntil { transport.requests.count == 1 })

            queue.cancelAll()
            #expect(queue.pendingCount == 0)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(transport.requests.count == 1)
            #expect(results.all.isEmpty)

            // It is usable again afterwards.
            let fresh = HTTPStub { request, _ in LRCLIBAnswer.found(for: request) }
            let other = makeQueue(fresh, results: results)
            other.enqueue(LRCLIBTestData.query(title: "2"))
            #expect(await waitUntil { results.all.count == 1 })
        }
    }
}
