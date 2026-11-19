// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Sends the calls for one scrobbling service one after the other, in the background, in the order they were added.
///
/// A call that fails for a temporary reason is tried again, waiting 1 s, 2 s, 4 s, ... (doubling) between tries (or
/// as long as the server asked for with `Retry-After`, at most 2 minutes, see `RetryDelay`), and given up on after
/// `maxAttempts` tries. Calls behind it wait: order matters, and a service that is down is down
/// for all of them. The service not accepting the credentials (`ScrobbleError.Kind.authentication`) drops everything
/// pending: it would all fail the same way. A call the service refuses for itself (`.rejected`) is dropped and the
/// queue goes on. Whatever happens, the queue takes new calls afterwards: the next one tries again, which is how a
/// service that was down (or whose password was fixed) is picked up again.
///
/// Nothing is kept on disk: what is still pending when the app quits is lost.
@MainActor
final class ScrobbleQueue {
    static let maxAttempts = 10

    enum Call: Equatable, Sendable {
        /// Check the credentials (Audioscrobbler: the handshake).
        case authenticate
        case nowPlaying(PlayedTrack)
        case scrobble(PlayedTrack)
        /// Playback stopped: nothing is playing now.
        case clearNowPlaying

        /// A call about the now playing status.
        var isNowPlayingStatus: Bool {
            switch self {
            case .nowPlaying, .clearNowPlaying: true
            case .authenticate, .scrobble: false
            }
        }

        /// Whether `later`, added after this call, makes it pointless. A now playing update or its clearing is stale
        /// as soon as another one comes (the track was switched, or playback stopped), and an update also when its
        /// track is scrobbled (it was left).
        func isSuperseded(by later: Call) -> Bool {
            switch self {
            case .nowPlaying(let track):
                if case .scrobble(let scrobbled) = later { return scrobbled == track }
                return later.isNowPlayingStatus
            case .clearNowPlaying:
                return later.isNowPlayingStatus
            case .authenticate, .scrobble:
                return false
            }
        }
    }

    private struct Job {
        let id: Int
        let call: Call
        let label: String
    }

    private let name: String
    private let client: any ScrobbleClient
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onDelivered: (Call) -> Void
    private let onFailure: (ScrobbleError) -> Void

    private var jobs: [Job] = []
    private var nextJobID = 0
    private var worker: Task<Void, Never>?

    /// Calls waiting or being tried.
    var pendingCount: Int { jobs.count }

    /// `name` is what the log says about the service. `sleep` is what waits between two tries; tests replace it.
    /// `onDelivered` is called for every call that went through, `onFailure` for every try that failed (also the
    /// ones that are repeated).
    init(name: String, client: any ScrobbleClient,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         onDelivered: @escaping (Call) -> Void, onFailure: @escaping (ScrobbleError) -> Void) {
        self.name = name
        self.client = client
        self.sleep = sleep
        self.onDelivered = onDelivered
        self.onFailure = onFailure
    }

    /// Adds a call at the end. A now playing update (or a clearing of it) that is still waiting behind others and is
    /// made pointless by the new call (`Call.isSuperseded`) is dropped. The one being tried stays for now: it may
    /// have reached the service already; if it has to be repeated, it is dropped then (see `deliver`).
    func enqueue(_ call: Call, label: String) {
        let before = jobs.count
        var index = jobs.startIndex + 1
        while index < jobs.endIndex {
            if jobs[index].call.isSuperseded(by: call) {
                jobs.remove(at: index)
            } else {
                index += 1
            }
        }
        if jobs.count != before { Log.info("scrobble[\(name)]: dropped \(before - jobs.count) outdated now playing call(s)") }
        nextJobID += 1
        jobs.append(Job(id: nextJobID, call: call, label: label))
        if worker == nil {
            worker = Task { [weak self] in await self?.work() }
        }
    }

    /// Forgets everything pending and stops, also what is being sent right now.
    func cancelAll() {
        worker?.cancel()
        worker = nil
        jobs.removeAll()
    }

    // MARK: - Internals

    private func work() async {
        while !Task.isCancelled, let job = jobs.first {
            guard await deliver(job) else { break }
        }
        // A cancelled worker was already replaced by `cancelAll`; a new one may be running.
        if !Task.isCancelled { worker = nil }
    }

    /// Tries `job` until it is done with, one way or the other. `false`: the queue stopped (cancelled, or the
    /// credentials aren't accepted).
    private func deliver(_ job: Job) async -> Bool {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await perform(job)
                jobs.removeAll { $0.id == job.id }
                onDelivered(job.call)
                return true
            } catch is CancellationError {
                return false
            } catch let error as ScrobbleError {
                onFailure(error)
                switch error.kind {
                case .authentication:
                    let dropped = jobs.count - 1
                    Log.error("scrobble[\(name)]: \(job.label): \(error)"
                        + (dropped > 0 ? ", dropped it and \(dropped) more waiting" : ", dropped"))
                    jobs.removeAll()
                    return false
                case .rejected:
                    Log.error("scrobble[\(name)]: \(job.label) was refused: \(error), dropped")
                    jobs.removeAll { $0.id == job.id }
                    return true
                case .temporary:
                    // A call that is outdated by now isn't repeated. If the server asked us to wait, the wait is kept
                    // (it is the service's pause, not the call's), and the call is dropped after it.
                    if isOutdated(job), error.retryAfter == nil {
                        dropOutdated(job)
                        return true
                    }
                    guard attempt < Self.maxAttempts else {
                        Log.error("scrobble[\(name)]: \(job.label) failed \(attempt) times (\(error)), dropped")
                        jobs.removeAll { $0.id == job.id }
                        return true
                    }
                    let delay = Self.delay(afterAttempt: attempt, retryAfter: error.retryAfter)
                    Log.error("scrobble[\(name)]: \(job.label) failed (\(error)), try \(attempt + 1)/\(Self.maxAttempts) in \(delay.components.seconds) s")
                    do { try await sleep(delay) } catch { return false }
                    if isOutdated(job) {
                        dropOutdated(job)
                        return true
                    }
                }
            } catch {
                onFailure(ScrobbleError(.rejected, error.localizedDescription))
                Log.error("scrobble[\(name)]: \(job.label) failed unexpectedly: \(error.localizedDescription), dropped")
                jobs.removeAll { $0.id == job.id }
                return true
            }
        }
    }

    /// Whether a call added after `job` makes it pointless.
    private func isOutdated(_ job: Job) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return false }
        return jobs[(index + 1)...].contains { job.call.isSuperseded(by: $0.call) }
    }

    private func dropOutdated(_ job: Job) {
        Log.info("scrobble[\(name)]: \(job.label) is outdated, dropped")
        jobs.removeAll { $0.id == job.id }
    }

    private func perform(_ job: Job) async throws {
        switch job.call {
        case .authenticate:
            let account = try await client.authenticate()
            Log.info("scrobble[\(name)]: authenticated" + (account.map { " as \($0)" } ?? ""))
        case .nowPlaying(let track):
            try await client.nowPlaying(track)
            Log.info("scrobble[\(name)]: \(job.label) sent")
        case .scrobble(let track):
            try await client.scrobble(track)
            Log.info("scrobble[\(name)]: \(job.label) sent")
        case .clearNowPlaying:
            try await client.clearNowPlaying()
            Log.info("scrobble[\(name)]: \(job.label) sent")
        }
    }

    /// What the server asked for, otherwise 1 s after the first try and twice as long each time.
    static func delay(afterAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> Duration {
        RetryDelay.delay(afterAttempt: attempt, retryAfter: retryAfter)
    }
}
