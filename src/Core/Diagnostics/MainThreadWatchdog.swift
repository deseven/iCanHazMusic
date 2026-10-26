// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Notices when the main thread stops responding (the UI hangs) and logs it: once it is stuck for `stuckReport`
/// seconds, and how long it was stuck once it answers again (only hangs of `threshold` seconds or more).
///
/// A background timer sends the main queue a ping every `interval` and waits for the answer. Rate limited: after a
/// report, further hangs are counted for `quietPeriod` and mentioned in the next report. The system's uptime doesn't
/// advance while the Mac sleeps, so sleeping isn't mistaken for a hang.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let threshold: TimeInterval = 2
    private let stuckReport: TimeInterval = 10
    private let interval: TimeInterval = 0.5
    private let quietPeriod: TimeInterval = 60

    private let queue = DispatchQueue(label: "wtf.d7.icanhazmusic.watchdog", qos: .utility)
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    /// When the ping that hasn't been answered yet was sent.
    private var pingSentAt: TimeInterval?
    private var reportedStuck = false
    private var lastReport: TimeInterval = -.infinity
    private var unreported = 0

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    private func check() {
        let now = Self.uptime
        if let sent = pingSentAt {
            if !reportedStuck, now - sent >= stuckReport {
                reportedStuck = true
                Log.error("main thread: not responding for \(Int(stuckReport)) s so far")
            }
            return
        }
        pingSentAt = now
        DispatchQueue.main.async { [self] in
            let answered = Self.uptime
            queue.async { self.answered(at: answered) }
        }
    }

    private func answered(at time: TimeInterval) {
        guard let sent = pingSentAt else { return }
        pingSentAt = nil
        let stuck = time - sent
        let wasReported = reportedStuck
        reportedStuck = false
        guard stuck >= threshold else { return }
        if !wasReported, time - lastReport < quietPeriod {
            unreported += 1
            return
        }
        lastReport = time
        let more = unreported > 0 ? ", \(unreported) more hang(s) since the last report" : ""
        unreported = 0
        Log.error("main thread: was not responding for \(String(format: "%.1f", stuck)) s\(more)")
    }
}
