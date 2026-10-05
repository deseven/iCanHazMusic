// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Sends the calls for one Last.fm session one after the other, in the background, in the order they were added.
///
/// A call that fails for a temporary reason is tried again, waiting 1 s, 2 s, 4 s, ... (doubling) between tries, and
/// given up on after `maxAttempts` tries. Calls behind it wait: order matters, and a service that is down is down
/// for all of them. Last.fm saying it doesn't accept the session (`LastFMError.Kind.authentication`) ends the queue:
/// everything pending is dropped and `onAuthenticationFailure` is called once. A call Last.fm refuses
/// for itself (`.rejected`) is dropped and the queue goes on.
///
/// Nothing is kept on disk: what is still pending when the app quits is lost.
@MainActor
final class LastFMQueue {
    static let maxAttempts = 10

    private struct Job {
        let id: Int
        let call: LastFMCall
        let label: String
    }

    private let client: LastFMClient
    private let sessionKey: String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onAuthenticationFailure: (LastFMError) -> Void

    private var jobs: [Job] = []
    private var nextJobID = 0
    private var worker: Task<Void, Never>?

    /// Calls waiting or being tried.
    var pendingCount: Int { jobs.count }

    /// `sleep` is what waits between two tries; tests replace it.
    init(client: LastFMClient, sessionKey: String,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         onAuthenticationFailure: @escaping (LastFMError) -> Void) {
        self.client = client
        self.sessionKey = sessionKey
        self.sleep = sleep
        self.onAuthenticationFailure = onAuthenticationFailure
    }

    /// Adds a call at the end. A now playing update that is still waiting behind others is stale by now and is
    /// replaced by the new one (the one being tried stays: it may have reached Last.fm already).
    func enqueue(_ call: LastFMCall, label: String) {
        if call.method == LastFMCall.updateNowPlayingMethod {
            let before = jobs.count
            var index = jobs.startIndex + 1
            while index < jobs.endIndex {
                if jobs[index].call.method == LastFMCall.updateNowPlayingMethod {
                    jobs.remove(at: index)
                } else {
                    index += 1
                }
            }
            if jobs.count != before { Log.info("last.fm: dropped \(before - jobs.count) outdated now playing update(s)") }
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
    /// session isn't accepted).
    private func deliver(_ job: Job) async -> Bool {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await client.send(job.call, sessionKey: sessionKey)
                Log.info("last.fm: \(job.label) sent")
                jobs.removeAll { $0.id == job.id }
                return true
            } catch is CancellationError {
                return false
            } catch let error as LastFMError {
                switch error.kind {
                case .authentication:
                    Log.error("last.fm: \(job.label): \(error), the session isn't accepted")
                    jobs.removeAll()
                    onAuthenticationFailure(error)
                    return false
                case .rejected:
                    Log.error("last.fm: \(job.label) was refused: \(error), dropped")
                    jobs.removeAll { $0.id == job.id }
                    return true
                case .temporary:
                    guard attempt < Self.maxAttempts else {
                        Log.error("last.fm: \(job.label) failed \(attempt) times (\(error)), dropped")
                        jobs.removeAll { $0.id == job.id }
                        return true
                    }
                    let delay = Self.delay(afterAttempt: attempt)
                    Log.info("last.fm: \(job.label) failed (\(error)), try \(attempt + 1)/\(Self.maxAttempts) in \(delay.components.seconds) s")
                    do { try await sleep(delay) } catch { return false }
                }
            } catch {
                return false
            }
        }
    }

    /// 1 s after the first try, then twice as long each time.
    static func delay(afterAttempt attempt: Int) -> Duration {
        .seconds(1 << min(max(attempt - 1, 0), 30))
    }
}
