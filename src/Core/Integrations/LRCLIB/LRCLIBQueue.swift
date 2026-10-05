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

/// Sends the LRCLIB lookups one after the other, in the background, like `LastFMQueue` does for Last.fm.
///
/// A lookup that fails for a temporary reason is tried again, waiting 1 s, 2 s, 4 s, ... (doubling) between tries
/// (or as long as LRCLIB asked for with `Retry-After`, if that is more), and given up on after `maxAttempts` tries.
/// Lookups behind it wait. LRCLIB asks for one request at a time with a pause between them, so `spacing` is waited
/// after every lookup. A lookup LRCLIB refuses for itself (`.rejected`) is dropped and the queue goes on.
///
/// Only the lookup being tried and the newest one are of interest: what waits behind the former is replaced when
/// another is added (the user is skipping through tracks, and what played a minute ago needs no lyrics now).
///
/// Nothing is kept on disk: what is still pending when the app quits is lost. `onResult` hears about every lookup that was
/// added, once (except after `cancelAll`).
@MainActor
final class LRCLIBQueue {
    static let maxAttempts = 10
    /// A `Retry-After` longer than this is not waited for (the try after it is the last chance anyway).
    static let maxRetryAfter: TimeInterval = 600

    private struct Job {
        let id: Int
        let query: LRCLIBQuery
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

    func enqueue(_ query: LRCLIBQuery) {
        let outdated = jobs.filter { $0.id != inFlight }
        if !outdated.isEmpty {
            jobs.removeAll { $0.id != inFlight }
            Log.info("lrclib: dropped \(outdated.count) outdated lookup(s)")
            for job in outdated { onResult(job.query, .failed) }
        }
        nextJobID += 1
        jobs.append(Job(id: nextJobID, query: query))
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
        while !Task.isCancelled, let job = jobs.first {
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
                    guard attempt < Self.maxAttempts else {
                        Log.error("lrclib: \(label) failed \(attempt) times (\(error)), dropped")
                        finish(job, .failed)
                        return true
                    }
                    let delay = Self.delay(afterAttempt: attempt, retryAfter: error.retryAfter)
                    Log.info("lrclib: \(label) failed (\(error)), try \(attempt + 1)/\(Self.maxAttempts) in \(delay.components.seconds) s")
                    do { try await sleep(delay) } catch { return false }
                }
            } catch {
                return false
            }
        }
    }

    private func finish(_ job: Job, _ outcome: LRCLIBOutcome) {
        jobs.removeAll { $0.id == job.id }
        onResult(job.query, outcome)
    }

    /// 1 s after the first try, then twice as long each time; at least what LRCLIB asked for.
    static func delay(afterAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> Duration {
        let backoff = 1 << min(max(attempt - 1, 0), 30)
        let asked = Int(min(max(retryAfter ?? 0, 0), maxRetryAfter).rounded(.up))
        return .seconds(max(backoff, asked))
    }
}
