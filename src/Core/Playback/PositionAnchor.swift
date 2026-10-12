// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Where the playback position was at one instant, and whether it moves on from there. Lets a view show the position
/// moving by itself (an animation run by the system) instead of being told about every step: `PlaybackState` only
/// replaces the anchor when something changes (pause, resume, seek, another track) or the engine drifts away from it.
struct PositionAnchor: Equatable {
    /// Seconds into the track at `uptime`.
    var position: Double
    /// `ProcessInfo.systemUptime` when `position` was true.
    var uptime: TimeInterval
    /// The position advances in real time (playing); false = it stays at `position`.
    var isRunning: Bool

    init(position: Double, isRunning: Bool, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.position = position
        self.isRunning = isRunning
        self.uptime = uptime
    }

    static let stopped = PositionAnchor(position: 0, isRunning: false, uptime: 0)

    /// The position at `uptime` (`ProcessInfo.systemUptime`).
    func position(at uptime: TimeInterval) -> Double {
        isRunning ? position + max(uptime - self.uptime, 0) : position
    }
}
