// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

/// A clock that stands still until told, and remembers what was waited for.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var elapsed: Duration = .zero
    private var waits: [Duration] = []

    var now: ContinuousClock.Instant { lock.withLock { origin + elapsed } }
    /// When (since the start) the waits ended, in the order they were asked.
    var waitedUntil: [Duration] { lock.withLock { waits } }

    func advance(_ duration: Duration) { lock.withLock { elapsed += duration } }

    func sleepUntil(_ instant: ContinuousClock.Instant) {
        lock.withLock { waits.append(origin.duration(to: instant)) }
    }
}

extension AllTests {
    @MainActor @Suite("Request spacer")
    struct RequestSpacerTests {
        private func makeSpacer(_ clock: FakeClock, interval: Duration = .seconds(1)) -> RequestSpacer {
            RequestSpacer(interval: interval, now: { clock.now }, sleepUntil: { clock.sleepUntil($0) })
        }

        @Test("the first request goes at once, the ones right behind it are a second apart")
        func spacing() async throws {
            let clock = FakeClock()
            let spacer = makeSpacer(clock)
            for _ in 0..<4 { try await spacer.wait() }
            #expect(clock.waitedUntil == [.seconds(1), .seconds(2), .seconds(3)])
        }

        @Test("time that passed on its own counts: no wait after a pause, and only the rest of it before that")
        func elapsedTime() async throws {
            let clock = FakeClock()
            let spacer = makeSpacer(clock)
            try await spacer.wait()                  // at 0
            clock.advance(.milliseconds(400))
            try await spacer.wait()                  // has to wait until 1 s
            clock.advance(.seconds(10))
            try await spacer.wait()                  // long after the previous one: at once
            try await spacer.wait()                  // 1 s after that one
            #expect(clock.waitedUntil == [.seconds(1), .milliseconds(11_400)])
        }

        @Test("the real throttle for MetaBrainz is a bit more than a second, as their docs ask")
        func metaBrainzInterval() {
            #expect(RequestSpacer.metaBrainzInterval >= .seconds(1))
            #expect(RequestSpacer.metaBrainzInterval <= .seconds(2))
        }
    }
}
