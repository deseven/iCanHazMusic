// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A ListenBrainz server. There is no session: every call carries the user token.
struct ListenBrainzClient: ScrobbleClient {
    let endpoint: String
    let token: String
    let transport: any HTTPTransport

    init(endpoint: String, token: String,
         transport: any HTTPTransport = URLSessionTransport(timeout: ScrobbleHTTP.requestTimeout)) {
        self.endpoint = endpoint
        self.token = token
        self.transport = transport
    }

    @discardableResult
    func authenticate() async throws -> String? {
        guard !token.isEmpty else { throw ScrobbleError(.authentication, "there is no user token") }
        guard let request = ListenBrainzAPI.validateRequest(endpoint: endpoint, token: token) else { throw invalidEndpoint }
        let answer = try await ScrobbleHTTP.perform(request, using: transport)
        return try ListenBrainzAPI.parseValidation(status: answer.status, body: answer.body)
    }

    func nowPlaying(_ track: PlayedTrack) async throws {
        try await submit(ListenBrainzAPI.nowPlayingRequest(track, endpoint: endpoint, token: token))
    }

    func scrobble(_ track: PlayedTrack) async throws {
        try await submit(ListenBrainzAPI.scrobbleRequest(track, endpoint: endpoint, token: token))
    }

    var canClearNowPlaying: Bool { true }

    func clearNowPlaying() async throws {
        guard let request = ListenBrainzAPI.clearNowPlayingRequest(endpoint: endpoint, token: token) else { throw invalidEndpoint }
        let answer = try await ScrobbleHTTP.perform(request, using: transport)
        try ListenBrainzAPI.checkClear(status: answer.status, body: answer.body)
    }

    private func submit(_ request: URLRequest?) async throws {
        guard let request else { throw invalidEndpoint }
        let answer = try await ScrobbleHTTP.perform(request, using: transport)
        try ListenBrainzAPI.check(status: answer.status, body: answer.body)
    }

    private var invalidEndpoint: ScrobbleError {
        ScrobbleError(.rejected, "the endpoint isn't a valid URL")
    }
}

extension ScrobbleServiceConfig {
    /// The client that talks to this service (settings as they are, no normalization).
    func makeClient(transport: any HTTPTransport) -> any ScrobbleClient {
        switch type {
        case .audioscrobbler:
            AudioscrobblerClient(endpoint: endpoint, username: username, password: secret, transport: transport)
        case .listenbrainz:
            ListenBrainzClient(endpoint: endpoint, token: secret, transport: transport)
        }
    }
}
