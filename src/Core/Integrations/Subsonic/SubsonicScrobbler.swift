// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

extension SubsonicConnection {
    /// Tells the server that the song was listened to, from `startedAt` (`scrobble` with `submission=true`, which counts
    /// a play and is passed on to whatever the server forwards plays to).
    func scrobble(songID: String, startedAt: Date) async throws {
        _ = try await call("scrobble", [
            ("id", songID),
            ("time", String(Int64((startedAt.timeIntervalSince1970 * 1000).rounded()))),
            ("submission", "true"),
        ])
    }
}

/// What a `ScrobbleQueue` sends a connection's scrobbles through: the song's server, by ID. "Now playing" isn't sent (the
/// queue is only given scrobbles). Looks the connection up when it sends, so a connection that was edited (a new
/// address) is used as it is by then, and one that is switched off or removed refuses.
struct SubsonicScrobbleClient: ScrobbleClient {
    let connectionID: UUID
    let service: SubsonicService

    func authenticate() async throws -> String? { nil }

    func nowPlaying(_ track: PlayedTrack) async throws {}

    func scrobble(_ track: PlayedTrack) async throws {
        guard let ref = track.url?.subsonicRef, ref.connection == connectionID else {
            throw ScrobbleError(.rejected, "the track is not a song of this connection")
        }
        guard let connection = await service.connection(connectionID) else {
            throw ScrobbleError(.rejected, "the connection is switched off or removed")
        }
        do {
            try await connection.scrobble(songID: ref.songID, startedAt: track.startedAt)
        } catch let error as SubsonicError {
            switch error.kind {
            case .connection: throw ScrobbleError(.temporary, error.message)
            case .authentication: throw ScrobbleError(.authentication, error.message)
            case .notFound, .rejected: throw ScrobbleError(.rejected, error.message)
            }
        }
    }
}

/// Scrobbles the songs of Subsonic servers (with "Send scrobbles" on) to the server they came from.
///
/// - A track that was listened to enough (`ScrobbleRule`: half of it, or 4 minutes) is scrobbled when it is left, with the
///   time it started at. Only songs of a connection that is switched on and has the setting on; nothing is sent
///   about files of this Mac or songs of other connections.
/// - Tags don't matter (a song is told by its ID), so unlike the other services a track without artist or title is sent too.
/// - Every connection has its own `ScrobbleQueue`: in the background, one call at a time, retried when the server can't
///   be reached (and not kept past the end of the app, like all of them).
@MainActor
final class SubsonicScrobbler: PlaybackListener {
    static let shared = SubsonicScrobbler(service: .shared)

    private let service: SubsonicService
    private let sleep: @Sendable (Duration) async throws -> Void
    private var queues: [UUID: ScrobbleQueue] = [:]

    init(service: SubsonicService, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.service = service
        self.sleep = sleep
    }

    /// How many scrobbles wait for a connection (for tests).
    func pendingCount(for connection: UUID) -> Int {
        queues[connection]?.pendingCount ?? 0
    }

    func trackDidStart(_ track: PlayedTrack) {}

    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval) {
        guard let ref = track.url?.subsonicRef,
              let connection = service.connections.first(where: { $0.id == ref.connection }),
              connection.enabled, connection.sendScrobbles,
              ScrobbleRule.isScrobbleWorthy(track, playedSeconds: playedSeconds) else { return }
        queue(for: connection).enqueue(.scrobble(track), label: "scrobble \(track.displayArtist) - \(track.displayTitle)")
    }

    private func queue(for connection: SubsonicConnectionConfig) -> ScrobbleQueue {
        if let existing = queues[connection.id] { return existing }
        let queue = ScrobbleQueue(name: "Subsonic \(connection.displayName)",
                                  client: SubsonicScrobbleClient(connectionID: connection.id, service: service),
                                  sleep: sleep, onDelivered: { _ in }, onFailure: { _ in })
        queues[connection.id] = queue
        return queue
    }
}
