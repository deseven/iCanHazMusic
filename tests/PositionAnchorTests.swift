// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("PositionAnchor")
    struct PositionAnchorTests {
        @Test("a running anchor moves with time, a paused one stays")
        func extrapolation() {
            let running = PositionAnchor(position: 10, isRunning: true, uptime: 100)
            #expect(running.position(at: 100) == 10)
            #expect(running.position(at: 107.5) == 17.5)
            #expect(running.position(at: 90) == 10)   // never goes backwards

            let paused = PositionAnchor(position: 10, isRunning: false, uptime: 100)
            #expect(paused.position(at: 107.5) == 10)
        }
    }
}
