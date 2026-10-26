// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Diagnostics")
    struct DiagnosticsTests {
        private func write(_ text: String, to url: URL) throws {
            try Data(text.utf8).write(to: url)
        }

        private func read(_ url: URL) -> String? {
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }

        // MARK: Log rotation

        @Test("the logs of earlier runs are shifted by one and the oldest is dropped")
        func rotation() throws {
            let dir = try TempDir()
            let log = dir.path("app.log")
            for run in 1...6 {
                Log.rotateLogs(at: log, keep: 4)
                try write("run \(run)", to: log)
            }
            #expect(read(log) == "run 6")
            #expect(read(dir.path("app.log.1")) == "run 5")
            #expect(read(dir.path("app.log.4")) == "run 2")
            #expect(read(dir.path("app.log.5")) == nil)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted()
            #expect(names == ["app.log", "app.log.1", "app.log.2", "app.log.3", "app.log.4"])
        }

        @Test("rotation copes with missing logs: the first run, a gap")
        func rotationGaps() throws {
            let dir = try TempDir()
            let log = dir.path("app.log")
            Log.rotateLogs(at: log, keep: 4)                      // nothing there yet
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)

            try write("old", to: dir.path("app.log.2"))
            try write("current", to: log)
            Log.rotateLogs(at: log, keep: 4)
            #expect(read(log) == nil)
            #expect(read(dir.path("app.log.1")) == "current")
            #expect(read(dir.path("app.log.3")) == "old")
        }

        // MARK: Slow calls

        @Test("slow calls are reported, quick ones aren't, and repeated ones are only counted for a while")
        func slowCalls() {
            let log = SlowCallLog(threshold: 0.5, quietPeriod: 60)
            var reports: [String] = []
            var time: TimeInterval = 1000
            log.report = { reports.append($0) }
            log.now = { time }

            log.record("engine.stop", seconds: 0.2)
            #expect(reports.isEmpty)
            log.record("engine.stop", seconds: 2.5)
            #expect(reports == ["slow call: engine.stop took 2.5 s on the main thread"])

            time += 10
            log.record("engine.stop", seconds: 1)
            log.record("engine.stop", seconds: 1)
            log.record("node.play", seconds: 0.7)                 // another call is reported on its own
            #expect(reports.count == 2)
            #expect(reports.last?.hasPrefix("slow call: node.play took 0.7 s") == true)

            time += 60
            log.record("engine.stop", seconds: 3)
            #expect(reports.count == 3)
            #expect(reports.last == "slow call: engine.stop took 3.0 s on the main thread, 2 more slow call(s) since the last report")
        }

        @Test("measuring hands back the result and reports with the time taken")
        func measure() {
            let log = SlowCallLog(threshold: 0.5)
            var reports: [String] = []
            var time: TimeInterval = 0
            log.report = { reports.append($0) }
            log.now = { time }
            let value = log.measure("slow") { () -> Int in
                time += 1.2
                return 42
            }
            #expect(value == 42)
            #expect(reports == ["slow call: slow took 1.2 s on the main thread"])
        }
    }
}
