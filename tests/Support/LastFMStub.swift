// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import iCanHazMusic

/// Stands in for Last.fm: `handler` answers every request (it also decides for how long, and whether, to fail).
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

    /// The form fields of every request received so far.
    var params: [[String: String]] { requests.map(Self.params(of:)) }

    /// The methods called so far, in order.
    var methods: [String] { params.compactMap { $0["method"] } }

    func perform(_ request: URLRequest) async throws -> HTTPAnswer {
        let index = lock.withLock { () -> Int in
            recorded.append(request)
            return recorded.count - 1
        }
        let answer = try await handler(request, index)
        return HTTPAnswer(status: answer.status, body: answer.body)
    }

    static func params(of request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            result[String(parts[0]).removingPercentEncoding ?? ""] = String(parts[1]).removingPercentEncoding ?? ""
        }
        return result
    }
}

/// Answers Last.fm gives.
enum LastFMAnswer {
    static let ok: StubTransport.Answer = (200, Data(#"{"status":"ok"}"#.utf8))

    static func error(_ code: Int, _ message: String = "error", status: Int = 403) -> StubTransport.Answer {
        (status, Data(#"{"message":"\#(message)","error":\#(code)}"#.utf8))
    }

    static func token(_ token: String = "tok") -> StubTransport.Answer {
        (200, Data(#"{"token":"\#(token)"}"#.utf8))
    }

    static func session(key: String = "sess", name: String = "someone") -> StubTransport.Answer {
        (200, Data(#"{"session":{"subscriber":0,"name":"\#(name)","key":"\#(key)"}}"#.utf8))
    }

    static let serverError: StubTransport.Answer = (500, Data("<html>oops</html>".utf8))
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

enum LastFMTestData {
    static let credentials = LastFMCredentials(apiKey: "KEY", secret: "SECRET")
    static let client = { (transport: StubTransport) in LastFMClient(credentials: credentials, transport: transport) }

    static func track(artist: String = "Artist", title: String = "Title", album: String = "Album",
                      duration: TimeInterval = 200, startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> PlayedTrack {
        PlayedTrack(artist: artist, title: title, album: album, duration: duration, startedAt: startedAt)
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
}
