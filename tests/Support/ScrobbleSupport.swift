// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import iCanHazMusic

/// Stands in for a scrobbling server: `handler` answers every request (it also decides for how long, and whether,
/// to fail).
final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Answer = (status: Int, body: Data)
    typealias Handler = @Sendable (URLRequest, _ index: Int) async throws -> Answer

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Answers `answer` to everything.
    convenience init(always answer: Answer) {
        self.init { _, _ in answer }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func perform(_ request: URLRequest) async throws -> HTTPAnswer {
        let index = lock.withLock { () -> Int in
            recorded.append(request)
            return recorded.count - 1
        }
        let answer = try await handler(request, index)
        return HTTPAnswer(status: answer.status, body: answer.body)
    }

    /// The form fields of a request body (`a[0]` and so on as they are named).
    static func form(of request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            result[String(parts[0]).removingPercentEncoding ?? ""] = String(parts[1]).removingPercentEncoding ?? ""
        }
        return result
    }

    /// The JSON body of a request.
    static func json(of request: URLRequest) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]) ?? [:]
    }
}

/// Answers the servers give.
enum ScrobbleAnswer {
    static func text(_ text: String, status: Int = 200) -> StubTransport.Answer {
        (status, Data(text.utf8))
    }

    // Audioscrobbler
    static let ok = text("OK\n")
    static let badSession = text("BADSESSION\n")
    static let serverError: StubTransport.Answer = (500, Data("<html>oops</html>".utf8))

    static func handshake(session: String = "SID", nowPlaying: String = "http://np.example.org/np",
                          submission: String = "http://sub.example.org/sub") -> StubTransport.Answer {
        text("OK\n\(session)\n\(nowPlaying)\n\(submission)\n")
    }

    // ListenBrainz
    static let accepted = text(#"{"status":"ok"}"#)

    static func tokenValid(user: String = "someone") -> StubTransport.Answer {
        text(#"{"code":200,"message":"Token valid.","valid":true,"user_name":"\#(user)"}"#)
    }

    static let tokenInvalid = text(#"{"code":200,"message":"Token invalid.","valid":false}"#)

    static func lbError(_ status: Int, _ message: String = "error") -> StubTransport.Answer {
        text(#"{"code":\#(status),"error":"\#(message)"}"#, status: status)
    }
}

/// Records the waits the queue asks for instead of waiting.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    /// Seconds, one entry per wait.
    var seconds: [Int] { lock.withLock { recorded } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            lock.withLock { recorded.append(Int(duration.components.seconds)) }
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

/// A `sleep` that stays in the wait until cancelled.
final class BlockingSleep: @unchecked Sendable {
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

/// Counts how many calls are in flight at once.
final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0

    var maxConcurrent: Int { lock.withLock { peak } }

    func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
}

/// A client that does what `handler` says, and keeps what it was asked.
final class FakeScrobbleClient: ScrobbleClient, @unchecked Sendable {
    enum Call: Equatable {
        case authenticate
        case nowPlaying(String)
        case scrobble(String)
        case clearNowPlaying
    }

    typealias Handler = @Sendable (Call, _ index: Int) async throws -> String?

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let handler: Handler

    init(_ handler: @escaping Handler = { _, _ in nil }) {
        self.handler = handler
    }

    var calls: [Call] { lock.withLock { recorded } }

    /// The titles of what was scrobbled, in order.
    var scrobbled: [String] {
        calls.compactMap { if case .scrobble(let title) = $0 { title } else { nil } }
    }

    private func record(_ call: Call) async throws -> String? {
        let index = lock.withLock { () -> Int in
            recorded.append(call)
            return recorded.count - 1
        }
        return try await handler(call, index)
    }

    func authenticate() async throws -> String? {
        try await record(.authenticate)
    }

    func nowPlaying(_ track: PlayedTrack) async throws {
        _ = try await record(.nowPlaying(track.title))
    }

    func scrobble(_ track: PlayedTrack) async throws {
        _ = try await record(.scrobble(track.title))
    }

    var canClearNowPlaying: Bool { true }

    func clearNowPlaying() async throws {
        _ = try await record(.clearNowPlaying)
    }
}

enum ScrobbleTestData {
    static func track(artist: String = "Artist", title: String = "Title", album: String = "Album",
                      duration: TimeInterval = 200, startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                      trackNumber: Int? = nil) -> PlayedTrack {
        PlayedTrack(artist: artist, title: title, album: album, duration: duration, startedAt: startedAt,
                    trackNumber: trackNumber)
    }
}

/// Keeps what `PlaybackState` tells its listener.
@MainActor
final class RecordingListener: PlaybackListener {
    enum Event: Equatable {
        case started(String)
        case ended(String)
    }

    private(set) var events: [Event] = []
    private(set) var started: [PlayedTrack] = []
    private(set) var ended: [(track: PlayedTrack, played: TimeInterval)] = []
    private(set) var playlistsEnded: [String] = []
    private(set) var queuesEnded = 0
    private(set) var stops = 0

    func trackDidStart(_ track: PlayedTrack) {
        started.append(track)
        events.append(.started(track.title))
    }

    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval) {
        ended.append((track, playedSeconds))
        events.append(.ended(track.title))
    }

    func playlistDidEnd(playlist: String) {
        playlistsEnded.append(playlist)
    }

    func queueDidEnd() {
        queuesEnded += 1
    }

    func playbackDidStop() {
        stops += 1
    }
}
