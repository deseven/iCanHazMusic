// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What went wrong with a call to a scrobbling service (or what stands for it: no connection, a 5xx). The kind says
/// what to do about it.
struct ScrobbleError: Error, Equatable, Sendable, CustomStringConvertible {
    enum Kind: Equatable, Sendable {
        /// Might work later: the server is down or busy, no connection, a garbled answer. Worth retrying.
        case temporary
        /// The credentials are not accepted (or the client is banned, or the clock is off) and will not be:
        /// everything waiting behind it would fail the same way.
        case authentication
        /// The server refuses this one request; sending it again changes nothing.
        case rejected
    }

    let kind: Kind
    let message: String
    /// How long the server asked to wait before the next try (`Retry-After`), seconds.
    var retryAfter: TimeInterval?

    init(_ kind: Kind, _ message: String, retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfter = retryAfter
    }

    var description: String { message }
}

/// What a client does for one service.
protocol ScrobbleClient: Sendable {
    /// Checks that the service accepts the credentials, and returns the name of the account if the service says it.
    /// For Audioscrobbler this is the handshake, for ListenBrainz the validation of the token.
    @discardableResult
    func authenticate() async throws -> String?

    func nowPlaying(_ track: PlayedTrack) async throws

    /// The track was listened to; `track.startedAt` is when it started playing.
    func scrobble(_ track: PlayedTrack) async throws

    /// Playback stopped: whatever was announced as now playing is not. Does nothing for a protocol that can't say it.
    func clearNowPlaying() async throws

    /// Whether `clearNowPlaying()` does anything.
    var canClearNowPlaying: Bool { get }
}

extension ScrobbleClient {
    func clearNowPlaying() async throws {}
    var canClearNowPlaying: Bool { false }
}

enum ScrobbleHTTP {
    /// A request that takes longer than this is given up on (and counts as a failed try).
    static let requestTimeout: TimeInterval = 60

    /// Sends `request`. Everything that goes wrong comes out as a `ScrobbleError`, except cancellation.
    static func perform(_ request: URLRequest, using transport: any HTTPTransport) async throws -> HTTPAnswer {
        let answer: HTTPAnswer
        do {
            answer = try await transport.perform(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No connection, a timeout, a reset...
            throw ScrobbleError(.temporary, error.localizedDescription)
        }
        try Task.checkCancellation()
        return answer
    }

    /// The error for an HTTP status that isn't a success. A busy or broken server is worth another try (after
    /// `retryAfter` seconds, if it said), anything else (a wrong address, for one) isn't.
    static func error(forStatus status: Int, detail: String? = nil, retryAfter: TimeInterval? = nil) -> ScrobbleError {
        let text = detail.map { "HTTP \(status): \($0)" } ?? "HTTP \(status)"
        switch status {
        case 408, 429, 500...599, 0: return ScrobbleError(.temporary, text, retryAfter: retryAfter)
        default: return ScrobbleError(.rejected, text)
        }
    }

    /// The beginning of an answer that isn't what was expected, for the message and the log.
    static func snippet(of body: Data, limit: Int = 120) -> String {
        let text = String(decoding: body.prefix(limit * 2), as: UTF8.self)
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return text.count > limit ? String(text.prefix(limit)) + "..." : text
    }
}

/// `application/x-www-form-urlencoded`, with the pairs in the order given.
enum FormEncoding {
    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0, allowing: keyCharacters))=\(escape($0.1, allowing: unreserved))" }
            .joined(separator: "&")
    }

    /// Everything except the unreserved characters is escaped (`&`, `=`, `+` and so on must not leak through).
    static func escape(_ text: String) -> String {
        escape(text, allowing: unreserved)
    }

    private static func escape(_ text: String, allowing set: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: set) ?? text
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// The indexes of `a[0]` stay as they are, like in the protocol's description.
    private static let keyCharacters = unreserved.union(CharacterSet(charactersIn: "[]"))
}
