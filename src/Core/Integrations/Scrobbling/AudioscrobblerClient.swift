// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// An Audioscrobbler 1.2.1 server. It keeps the session of the last handshake and does the handshake again when the
/// protocol says to: when the server calls the session invalid (once per call, so a server that insists on it can't
/// make this loop), and after three failures in a row.
///
/// An actor because it has the session, but calls are made one at a time (by `ScrobbleQueue`).
actor AudioscrobblerClient: ScrobbleClient {
    /// This many failures in a row mean the session is not to be trusted any more.
    static let maxConsecutiveFailures = 3

    private let endpoint: String
    private let username: String
    private let password: String
    private let transport: any HTTPTransport
    private let clock: @Sendable () -> Date

    private var session: AudioscrobblerSession?
    private var consecutiveFailures = 0

    init(endpoint: String, username: String, password: String,
         transport: any HTTPTransport = URLSessionTransport(timeout: ScrobbleHTTP.requestTimeout),
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.transport = transport
        self.clock = clock
    }

    @discardableResult
    func authenticate() async throws -> String? {
        try await handshake()
        return username.isEmpty ? nil : username
    }

    func nowPlaying(_ track: PlayedTrack) async throws {
        try await send { AudioscrobblerAPI.nowPlayingRequest(track, session: $0) }
    }

    func scrobble(_ track: PlayedTrack) async throws {
        try await send { AudioscrobblerAPI.submissionRequest(track, session: $0) }
    }

    // MARK: - Internals

    @discardableResult
    private func handshake() async throws -> AudioscrobblerSession {
        session = nil
        let timestamp = Int(clock().timeIntervalSince1970)
        guard let request = AudioscrobblerAPI.handshakeRequest(
            endpoint: endpoint, username: username, password: password, timestamp: timestamp) else {
            throw ScrobbleError(.rejected, "the endpoint isn't a valid URL")
        }
        let answer = try await ScrobbleHTTP.perform(request, using: transport)
        let fresh = try AudioscrobblerAPI.parseHandshake(status: answer.status, body: answer.body)
        session = fresh
        consecutiveFailures = 0
        return fresh
    }

    /// Sends the request `build` makes for the current session (a handshake first if there is none).
    private func send(_ build: (AudioscrobblerSession) -> URLRequest) async throws {
        var shookHandsAgain = false
        while true {
            let current: AudioscrobblerSession
            if let session { current = session } else { current = try await handshake() }
            do {
                let answer = try await ScrobbleHTTP.perform(build(current), using: transport)
                switch try AudioscrobblerAPI.parseReply(status: answer.status, body: answer.body) {
                case .ok:
                    consecutiveFailures = 0
                    return
                case .badSession:
                    session = nil
                    guard !shookHandsAgain else {
                        throw ScrobbleError(.temporary, "the server keeps calling the session invalid (BADSESSION)")
                    }
                    shookHandsAgain = true
                    Log.info("scrobbling: \(endpoint): the session is not valid any more, shaking hands again")
                }
            } catch let error as ScrobbleError where error.kind == .temporary {
                consecutiveFailures += 1
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    Log.info("scrobbling: \(endpoint): \(consecutiveFailures) failures in a row, the next call shakes hands again")
                    session = nil
                    consecutiveFailures = 0
                }
                throw error
            }
        }
    }
}
