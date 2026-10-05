// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import iCanHazMusic

/// A `PlaybackEngine` rendering offline, with everything it outputs kept in `out` (absolute frame numbers = indexes)
/// and every event it reported in `events`.
///
/// `render` lets the feeder work between the steps, the way it does in the app between two device callbacks. Steps
/// are one engine render slice (1024 frames) by default, which makes the frame at which a command takes effect
/// predictable: see `commitFrame`.
@MainActor
final class EngineRig {
    let engine: PlaybackEngine
    let rate: Double
    private(set) var out: [[Float]] = [[], []]
    private(set) var events: [String] = []
    /// Called for every event, after it was recorded.
    var react: ((PlaybackEngine.Event) -> Void)?

    init(rate: Double = 44100, lookahead: Double = 60) {
        self.rate = rate
        engine = PlaybackEngine(output: .offline(sampleRate: rate), lookahead: lookahead)
        engine.onEvent = { [weak self] event in
            self?.record(event)
            self?.react?(event)
        }
    }

    func record(_ event: PlaybackEngine.Event) {
        events.append(Self.describe(event))
    }

    static func describe(_ event: PlaybackEngine.Event) -> String {
        switch event {
        case .advanced: "advanced"
        case .finished: "finished"
        case .failed(let url, let wasCurrent, _): "failed:\(url.lastPathComponent):\(wasCurrent ? "current" : "next")"
        case .deviceError: "deviceError"
        }
    }

    /// Frames rendered so far.
    var frame: Int { out.frameCount }

    private var chunksSeen = 0

    /// Lets the feeder do its work, then gives the player node time to take up what was scheduled.
    ///
    /// The node picks up a buffer scheduled while it runs on its own thread, a few milliseconds later. A device
    /// doesn't care, but an offline render right after scheduling can miss the buffer, and the audio then comes
    /// out some slices late (observed: 0 to 2048 frames, anything the queue didn't already cover). Waiting makes
    /// the output deterministic.
    func settle() async {
        await engine.settle()
        guard engine.scheduledChunks != chunksSeen else { return }
        chunksSeen = engine.scheduledChunks
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Renders `frames`, with the feeder working before the first step and after each step.
    func render(_ frames: Int, step: Int = PlaybackEngine.renderSlice, settle: Bool = true) async throws {
        var left = frames
        if settle { await self.settle() }
        while left > 0 {
            let n = min(step, left)
            out.append(try engine.renderOffline(n))
            left -= n
            if settle { await self.settle() }
        }
    }

    /// Renders `frames` straight from the engine: no feeder in between, not even before the first step.
    func renderWithoutFeeding(_ frames: Int) throws {
        out.append(try engine.renderOffline(frames))
    }

    /// Renders until the engine has nothing loaded any more (or `limit` frames passed).
    func renderUntilIdle(limit: Int = 2_000_000) async throws {
        var rendered = 0
        while engine.isActive, rendered < limit {
            try await render(PlaybackEngine.renderSlice)
            rendered += PlaybackEngine.renderSlice
        }
    }

    /// Output frames a fade takes in this rig: the number of render slices needed to cover `fadeDuration`.
    var fadeFrames: Int {
        let slices = Int((PlaybackEngine.fadeDuration * rate / Double(PlaybackEngine.renderSlice)).rounded(.up))
        return slices * PlaybackEngine.renderSlice
    }

    /// Where a command given now (between two `render` calls with the default step) takes effect: the end of the
    /// slice in which its fade-out completes.
    var commitFrame: Int { frame + fadeFrames }

    /// Frames from the fade-in to count as "fully faded in" (the ramp is about 25 ms).
    var fadeInFrames: Int { Int(0.04 * rate) }

    // MARK: Checking

    /// Deviation of the output from `file` played from `fileFrame`, with its first frame at output frame `at`.
    func deviation(of file: RampFile, from fileFrame: Int, at: Int, count: Int) -> Float {
        maxDeviation(out, from: at, count: count) { file.stereo(fileFrame + $0, channel: $1) }
    }

    /// The first frame at or after `start` where the output isn't silent; nil if there is none.
    func firstSound(from start: Int = 0) -> Int? {
        (start..<frame).first { out[0][$0] != 0 || out[1][$0] != 0 }
    }

    /// Number of frames in `range` that aren't silent.
    func soundFrames(in range: Range<Int>) -> Int {
        range.reduce(0) { $0 + (out[0][$1] != 0 || out[1][$1] != 0 ? 1 : 0) }
    }
}
