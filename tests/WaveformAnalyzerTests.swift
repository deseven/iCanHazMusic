// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Waveform: analyzer")
    struct WaveformAnalyzerTests {
        private func analyse(_ url: URL, workers: Int = WaveformAnalyzer.workers) -> WaveformAnalysis? {
            WaveformAnalyzer.analyse(url: url, workers: workers) { false }
        }

        /// What the levels of a ramp file must be, from its known content.
        private func expectedLevels(_ file: RampFile) -> [UInt8] {
            let bucketFrames = (file.frames + Waveform.bucketCount - 1) / Waveform.bucketCount
            let buckets = (file.frames + bucketFrames - 1) / bucketFrames
            return (0..<buckets).map { bucket in
                let start = bucket * bucketFrames
                let end = min(file.frames, start + bucketFrames)
                var sum = 0.0
                for frame in start..<end {
                    for channel in 0..<2 {
                        let value = Double(file.stereo(frame, channel: channel))
                        sum += value * value
                    }
                }
                return Waveform.level(forRMS: (sum / Double(2 * (end - start))).squareRoot())
            }
        }

        private func expectClose(_ levels: [UInt8], to expected: [UInt8], tolerance: Int = 1, _ comment: String = "") {
            #expect(levels.count == expected.count, "\(comment) bucket count")
            guard levels.count == expected.count else { return }
            let worst = zip(levels, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst <= tolerance, "\(comment) worst deviation \(worst) levels")
        }

        @Test("a file is cut into 2048 buckets (fewer frames: one bucket per frame) whose levels match the content")
        func levels() throws {
            for file in [RampFile.a, .b, .r48, .r96, .tiny, .tiny2] {
                let result = try #require(analyse(try file.url()), "\(file.name)")
                #expect(result.isComplete, "\(file.name)")
                expectClose(result.waveform.levels, to: expectedLevels(file), file.name)
            }
            #expect(try #require(analyse(try RampFile.tiny2.url())).waveform.levels.count == RampFile.tiny2.frames)
            #expect(try #require(analyse(try RampFile.a.url())).waveform.levels.count <= Waveform.bucketCount)
        }

        @Test("mono is on both sides")
        func mono() throws {
            let result = try #require(analyse(try RampFile.mono22.url()))
            #expect(result.isComplete)
            expectClose(result.waveform.levels, to: expectedLevels(.mono22))
        }

        @Test("more than two channels are folded down, not ignored")
        func surround() throws {
            let result = try #require(analyse(try RampFile.surround.url()))
            #expect(result.isComplete)
            #expect(result.waveform.levels.count > 1000)
            #expect(result.waveform.levels.allSatisfy { $0 > 50 })
        }

        @Test("a tone of amplitudes 0.5 and 0.25 has the power of both on average")
        func tone() throws {
            let result = try #require(analyse(try ToneFile.sine44.url()))
            let powers = result.waveform.levels.map { Waveform.rms(forLevel: $0) }.map { $0 * $0 }
            let mean = powers.reduce(0, +) / Double(powers.count)
            let expected = (0.5 * 0.5 / 2 + 0.25 * 0.25 / 2) / 2
            #expect(abs(10 * log10(mean / expected)) < 0.5)
        }

        @Test("the result is the same for any number of workers")
        func workers() throws {
            for file in [RampFile.a, .b, .tiny, .tiny2, .r96, .surround, .mono22] {
                let url = try file.url()
                let one = try #require(analyse(url, workers: 1)).waveform
                for workers in [2, 3, 8, 5000] {
                    #expect(try #require(analyse(url, workers: workers)).waveform == one, "\(file.name), \(workers) workers")
                }
            }
        }

        @Test("every container gives the same levels with workers that seek into the file")
        func containers() throws {
            let reference = expectedLevels(.a)
            for name in ["a.wav", "a.aiff", "a.caf", "a_alac.m4a", "a.flac"] {
                let url = try Fixtures.url("playback/" + name)
                for workers in [1, 2, 3] {
                    let result = try #require(analyse(url, workers: workers), "\(name)")
                    #expect(result.isComplete, "\(name)")
                    expectClose(result.waveform.levels, to: reference, "\(name), \(workers) workers")
                }
            }
        }

        @Test("a lossy file gives about the same levels with one worker and with several")
        func lossy() throws {
            for name in ["lossy.mp3", "lossy_vbr.mp3", "lossy.m4a", "lossy.ogg"] {
                let url = try Fixtures.url("playback/" + name)
                let one = try #require(analyse(url, workers: 1), Comment(rawValue: name)).waveform.levels
                let two = try #require(analyse(url, workers: 2), Comment(rawValue: name)).waveform.levels
                // Vorbis seeks 20 ms late (dev-docs/playback.md): the end of the second slice is cut off, which in
                // these 3 second files, with buckets of 65 frames, is a dozen buckets. In a real track it is a fraction
                // of one.
                let skipped = 20
                #expect(one.count == two.count, Comment(rawValue: name))
                expectClose(Array(two.dropLast(skipped)), to: Array(one.dropLast(skipped)), tolerance: 8, name)
            }
        }

        @Test("a missing, empty or garbage file has no waveform")
        func unreadable() throws {
            #expect(analyse(try TempDir().path("nope.flac")) == nil)
            #expect(analyse(try Fixtures.url("broken/garbage.mp3")) == nil)
            #expect(analyse(try Fixtures.url("broken/empty.flac")) == nil)
        }

        @Test("a file that ends before it said it would gives a result that is flagged as incomplete")
        func truncated() throws {
            let result = try #require(analyse(try Fixtures.url("playback/truncated.flac")))
            #expect(!result.isComplete)
            #expect(!result.waveform.levels.isEmpty)
        }

        @Test("a cancelled pass gives nothing, quickly")
        func cancelled() throws {
            let started = Date()
            #expect(WaveformAnalyzer.analyse(url: try RampFile.a.url(), workers: 2) { true } == nil)
            #expect(Date().timeIntervalSince(started) < 1)

            let counter = Counter()
            let result = WaveformAnalyzer.analyse(url: try RampFile.a.url(), workers: 1) { counter.next() > 3 }
            #expect(result == nil)
        }

        @Test("the background variant gives the same result")
        func background() async throws {
            let url = try RampFile.b.url()
            let result = await WaveformAnalyzer.analyse(url: url)
            #expect(result == analyse(url))
            #expect(result != nil)
        }

        @Test("cancelling the task cancels the pass")
        func cancelTask() async throws {
            let url = try RampFile.a.url()
            let task = Task { await WaveformAnalyzer.analyse(url: url) }
            task.cancel()
            // Either the pass hadn't started (nil) or it noticed the cancellation; it never delivers a wrong result.
            let result = await task.value
            if let result { #expect(result == analyse(url)) }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
