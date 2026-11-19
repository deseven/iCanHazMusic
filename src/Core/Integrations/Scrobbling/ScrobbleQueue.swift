// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Sends the calls for one scrobbling service one after the other, in the background, in the order they were added.
///
/// A call that fails for a temporary reason is tried again, waiting 1 s, 2 s, 4 s, ... (doubling) between tries, and
/// given up on after `maxAttempts` tries. Calls behind it wait: order matters, and a service that is down is down
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

        /// A call about the now playing status: one that waits behind others is stale as soon as another comes.
        var isNowPlayingStatus: Bool {
            switch self {
            case .nowPlaying, .clearNowPlaying: true
            case .authenticate, .scrobble: false
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

    /// Adds a call at the end. A now playing update (or a clearing of it) that is still waiting behind others is
    /// stale by now and is replaced by the new one (the one being tried stays: it may have reached the service already).
    func enqueue(_ call: Call, label: String) {
        if call.isNowPlayingStatus {
            let before = jobs.count
            var index = jobs.startIndex + 1
            while index < jobs.endIndex {
                if jobs[index].call.isNowPlayingStatus {
                    jobs.remove(at: index)
                } else {
                    index += 1
                }
            }
            if jobs.count != before { Log.info("scrobble[\(name)]: dropped \(before - jobs.count) outdated now playing call(s)") }
        }
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
                    guard attempt < Self.maxAttempts else {
                        Log.error("scrobble[\(name)]: \(job.label) failed \(attempt) times (\(error)), dropped")
                        jobs.removeAll { $0.id == job.id }
                        return true
                    }
                    let delay = Self.delay(afterAttempt: attempt)
                    Log.error("scrobble[\(name)]: \(job.label) failed (\(error)), try \(attempt + 1)/\(Self.maxAttempts) in \(delay.components.seconds) s")
                    do { try await sleep(delay) } catch { return false }
                }
            } catch {
                onFailure(ScrobbleError(.rejected, error.localizedDescription))
                Log.error("scrobble[\(name)]: \(job.label) failed unexpectedly: \(error.localizedDescription), dropped")
                jobs.removeAll { $0.id == job.id }
                return true
            }
        }
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

    /// 1 s after the first try, then twice as long each time.
    static func delay(afterAttempt attempt: Int) -> Duration {
        .seconds(1 << min(max(attempt - 1, 0), 30))
    }
}
