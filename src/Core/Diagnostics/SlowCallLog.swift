// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Times blocking calls made on the main thread (CoreAudio, mostly: starting/stopping the output can hang on a device
/// in a bad state) and logs the ones that take longer than `threshold`.
///
/// Rate limited per call name: after a report, further slow calls of the same name are only counted for `quietPeriod`
/// and mentioned in the next report, so a call that is slow on every tick doesn't flood the log.
@MainActor
final class SlowCallLog {
    let threshold: TimeInterval
    let quietPeriod: TimeInterval
    /// Where reports go (replaced by tests).
    var report: (String) -> Void = { Log.error($0) }
    /// The time in seconds (replaced by tests).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var lastReport: [String: TimeInterval] = [:]
    private var unreported: [String: Int] = [:]

    init(threshold: TimeInterval = 0.5, quietPeriod: TimeInterval = 60) {
        self.threshold = threshold
        self.quietPeriod = quietPeriod
    }

    /// Runs `body`, and reports it if it took long.
    func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = now()
        defer { record(name, seconds: now() - start) }
        return try body()
    }

    /// Notes that `name` took `seconds`.
    func record(_ name: String, seconds: TimeInterval) {
        guard seconds >= threshold else { return }
        let time = now()
        if let last = lastReport[name], time - last < quietPeriod {
            unreported[name, default: 0] += 1
            return
        }
        lastReport[name] = time
        let more = unreported.removeValue(forKey: name).map { ", \($0) more slow call(s) since the last report" } ?? ""
        report("slow call: \(name) took \(String(format: "%.1f", seconds)) s on the main thread\(more)")
    }
}
