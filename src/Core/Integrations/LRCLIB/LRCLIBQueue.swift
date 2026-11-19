// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// How a lookup ended.
enum LRCLIBOutcome: Equatable, Sendable {
    /// LRCLIB has the lyrics of the track.
    case found(Lyrics)
    /// LRCLIB answered, and doesn't have them (yet).
    case notFound
    /// No answer: given up after the tries, refused, or replaced by a newer lookup.
    case failed
}

/// Sends the LRCLIB lookups one after the other, in the background, like `ScrobbleQueue` does for the scrobbling services.
///
/// A lookup that fails for a temporary reason is tried again, waiting 1 s, 2 s, 4 s, ... (doubling) between tries
/// (or as long as LRCLIB asked for with `Retry-After`, at most 2 minutes, see `RetryDelay`), and given up on after
/// `maxAttempts` tries.
/// Lookups behind it wait. LRCLIB asks for one request at a time with a pause between them, so `spacing` is waited
/// after every lookup. A lookup LRCLIB refuses for itself (`.rejected`) is dropped and the queue goes on.
///
/// Only the newest lookup is of interest: what waits behind the one being tried is replaced when another is added
/// (the user is skipping through tracks, and what played a minute ago needs no lyrics now). The one being tried is
/// not repeated either once a newer one is there: if LRCLIB asked to wait, that is still waited out (it is LRCLIB's
/// pause, and the newer lookup goes after it), then the old one is dropped.
/// One queue for everything, not one per track: LRCLIB wants one request at a time, and what it asks to wait for is
/// meant for all of our requests.
/// Exception: a *retry* (`enqueue(_:isRetry:)`, a second look for lyrics LRCLIB didn't have yet) is never replaced and
/// never replaces anything, but it goes after every regular lookup. It still shares the queue, so LRCLIB gets one
/// request at a time with `spacing` between them whatever the reason for the request.
///
/// Nothing is kept on disk: what is still pending when the app quits is lost. `onResult` hears about every lookup that was
/// added, once (except after `cancelAll`).
@MainActor
final class LRCLIBQueue {
    static let maxAttempts = 10

    private struct Job {
        let id: Int
        let query: LRCLIBQuery
        let isRetry: Bool
    }

    private let client: LRCLIBClient
    private let sleep: @Sendable (Duration) async throws -> Void
    private let spacing: Duration
    private let onResult: (LRCLIBQuery, LRCLIBOutcome) -> Void

    private var jobs: [Job] = []
    private var inFlight: Int?
    private var nextJobID = 0
    private var worker: Task<Void, Never>?

    /// Lookups waiting or being tried.
    var pendingCount: Int { jobs.count }

    /// `sleep` is what waits between two tries (and `spacing` between two lookups); tests replace it.
    init(client: LRCLIBClient,
         spacing: Duration = .milliseconds(300),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         onResult: @escaping (LRCLIBQuery, LRCLIBOutcome) -> Void) {
        self.client = client
        self.spacing = spacing
        self.sleep = sleep
        self.onResult = onResult
    }

    func enqueue(_ query: LRCLIBQuery, isRetry: Bool = false) {
        if !isRetry {
            let outdated = jobs.filter { $0.id != inFlight && !$0.isRetry }
            if !outdated.isEmpty {
                jobs.removeAll { $0.id != inFlight && !$0.isRetry }
                Log.info("lrclib: dropped \(outdated.count) outdated lookup(s)")
                for job in outdated { onResult(job.query, .failed) }
            }
        }
        nextJobID += 1
        jobs.append(Job(id: nextJobID, query: query, isRetry: isRetry))
        if worker == nil {
            worker = Task { [weak self] in await self?.work() }
        }
    }

    /// Forgets everything pending and stops, also what is being sent right now. Nobody is told.
    func cancelAll() {
        worker?.cancel()
        worker = nil
        jobs.removeAll()
        inFlight = nil
    }

    // MARK: - Internals

    private func work() async {
        while !Task.isCancelled, let job = jobs.first(where: { !$0.isRetry }) ?? jobs.first {
            inFlight = job.id
            guard await deliver(job) else { break }
            inFlight = nil
            if spacing > .zero {
                do { try await sleep(spacing) } catch { break }
            }
        }
        // A cancelled worker was already replaced by `cancelAll`; a new one may be running.
        if !Task.isCancelled {
            inFlight = nil
            worker = nil
        }
    }

    /// Tries `job` until it is done with, one way or the other. `false`: the queue stopped (cancelled).
    private func deliver(_ job: Job) async -> Bool {
        let label = "\(job.query.artist) - \(job.query.title)"
        var attempt = 0
        while true {
            attempt += 1
            do {
                let lyrics = try await client.lookup(job.query)
                Log.info("lrclib: \(label): \(lyrics == nil ? "no match" : "found")")
                finish(job, lyrics.map(LRCLIBOutcome.found) ?? .notFound)
                return true
            } catch is CancellationError {
                return false
            } catch let error as LRCLIBError {
                switch error.kind {
                case .rejected:
                    Log.error("lrclib: \(label) was refused: \(error), dropped")
                    finish(job, .failed)
                    return true
                case .temporary:
                    if isOutdated(job), error.retryAfter == nil {
                        Log.info("lrclib: \(label) failed (\(error)) and is outdated, dropped")
                        finish(job, .failed)
                        return true
                    }
                    guard attempt < Self.maxAttempts else {
                        Log.error("lrclib: \(label) failed \(attempt) times (\(error)), dropped")
                        finish(job, .failed)
                        return true
                    }
                    let delay = Self.delay(afterAttempt: attempt, retryAfter: error.retryAfter)
                    Log.info("lrclib: \(label) failed (\(error)), try \(attempt + 1)/\(Self.maxAttempts) in \(delay.components.seconds) s")
                    do { try await sleep(delay) } catch { return false }
                    if isOutdated(job) {
                        Log.info("lrclib: \(label) is outdated, dropped")
                        finish(job, .failed)
                        return true
                    }
                }
            } catch {
                return false
            }
        }
    }

    /// A regular lookup is outdated when a newer regular one is waiting. Retries are never outdated.
    private func isOutdated(_ job: Job) -> Bool {
        !job.isRetry && jobs.contains { $0.id > job.id && !$0.isRetry }
    }

    private func finish(_ job: Job, _ outcome: LRCLIBOutcome) {
        jobs.removeAll { $0.id == job.id }
        onResult(job.query, outcome)
    }

    /// What LRCLIB asked for, otherwise 1 s after the first try and twice as long each time.
    static func delay(afterAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> Duration {
        RetryDelay.delay(afterAttempt: attempt, retryAfter: retryAfter)
    }
}
