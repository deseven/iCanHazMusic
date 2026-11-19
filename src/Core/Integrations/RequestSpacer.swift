// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Hands out time slots so that the requests of whoever asks are at least `interval` apart: the first goes through
/// at once, the next waits until `interval` after the previous one started, and so on. Callers are served in the
/// order they asked. The slot is taken before waiting, so a caller that is cancelled while waiting still uses its up
/// (the next one doesn't hurry).
actor RequestSpacer {
    /// All requests to MetaBrainz hosts (`AppConstants.isMetaBrainzHost`) in this process share this one: their
    /// limit is per client, whichever of the services (scrobbling, a connection test, ...) the request is for.
    static let metaBrainz = RequestSpacer(interval: metaBrainzInterval)

    /// ListenBrainz: "never more than ONE call per second". A margin on top of it, for the jitter of the network.
    static let metaBrainzInterval: Duration = .milliseconds(1100)

    private let interval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var nextSlot: ContinuousClock.Instant?

    /// `now` and `sleepUntil` are the clock; tests replace them.
    init(interval: Duration,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = { try await Task.sleep(until: $0) }) {
        self.interval = interval
        self.now = now
        self.sleepUntil = sleepUntil
    }

    /// Returns when it is this caller's turn. Throws `CancellationError` if the task is cancelled while waiting.
    func wait() async throws {
        let current = now()
        let start = max(nextSlot ?? current, current)
        nextSlot = start + interval
        if start > current { try await sleepUntil(start) }
    }
}
