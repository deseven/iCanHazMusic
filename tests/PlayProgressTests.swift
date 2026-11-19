// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Play progress")
    struct PlayProgressTests {
        @Test("normal progress adds up, jumps and going back don't, and a pause (same position) adds nothing")
        func observing() {
            var progress = PlayProgress(track: ScrobbleTestData.track())
            for second in stride(from: 0.25, through: 2, by: 0.25) { progress.observe(position: second) }
            #expect(abs(progress.played - 2) < 1e-9)

            progress.observe(position: 2)            // paused
            #expect(abs(progress.played - 2) < 1e-9)

            progress.observe(position: 90)           // seek forward
            #expect(abs(progress.played - 2) < 1e-9)
            progress.observe(position: 90.25)
            #expect(abs(progress.played - 2.25) < 1e-9)

            progress.observe(position: 10)           // seek back
            progress.observe(position: 10.5)
            #expect(abs(progress.played - 2.75) < 1e-9)
        }

        @Test("a track picked up at half of its length or later counts as listened to up to there, an earlier one from scratch")
        func resumed() {
            let length = 100.0

            var late = PlayProgress(track: ScrobbleTestData.track(), resumedAt: 60)
            #expect(late.listened(ofDuration: length) == 60)            // nothing heard since: the part before counts
            late.observe(position: 60.5)
            late.observe(position: 61)                                   // the counting goes on from where it was picked up
            #expect(abs(late.played - 1) < 1e-9)
            #expect(abs(late.listened(ofDuration: length) - 61) < 1e-9)
            #expect(late.listened(ofDuration: 0) == late.played)         // a length that isn't known: no credit

            let half = PlayProgress(track: ScrobbleTestData.track(), resumedAt: 50)
            #expect(half.listened(ofDuration: length) == 50)             // exactly half is enough, like for a scrobble

            var early = PlayProgress(track: ScrobbleTestData.track(), resumedAt: 49)
            #expect(early.listened(ofDuration: length) == 0)
            early.observe(position: 49.5)
            early.observe(position: 50)
            #expect(abs(early.listened(ofDuration: length) - 1) < 1e-9)

            // Never more than the track has.
            var end = PlayProgress(track: ScrobbleTestData.track(), resumedAt: 99)
            for step in 1...6 { end.observe(position: 99 + Double(step) * 0.25) }
            #expect(end.listened(ofDuration: length) == length)
        }

        @Test("for a long track the point where it counts is 4 minutes")
        func resumedInLongTrack() {
            let length = 1000.0
            #expect(PlayProgress(track: ScrobbleTestData.track(), resumedAt: 240).listened(ofDuration: length) == 240)
            #expect(PlayProgress(track: ScrobbleTestData.track(), resumedAt: 239).listened(ofDuration: length) == 0)
        }
    }
}
