// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// The engine rendering offline: what comes out is compared sample by sample with what the files contain.
    @MainActor @Suite("PlaybackEngine: playing")
    struct PlaybackEngineTests {
        private static let slice = PlaybackEngine.renderSlice

        // MARK: A single track

        @Test("a track plays exactly its samples, then silence, then the engine reports the end")
        func plainPlayback() async throws {
            let rig = EngineRig()
            let file = RampFile.a
            rig.engine.start(try file.url())
            try await rig.render(file.frames + 5000)

            #expect(rig.deviation(of: file, from: 0, at: 0, count: file.frames) == 0)
            #expect(isSilent(rig.out, in: file.frames..<rig.frame))
            #expect(rig.events == ["finished"])
            #expect(!rig.engine.isActive)
            #expect(rig.engine.position == 0)
        }

        @Test("the output starts with the first sample, without a fade-in or an offset")
        func firstSample() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            try await rig.render(2048)
            #expect(rig.out[0][0] == RampFile.a.value(0, channel: 0))
            #expect(rig.out[1][0] == RampFile.a.value(0, channel: 1))
            #expect(rig.out[0][1] == RampFile.a.value(1, channel: 0))
        }

        @Test("nothing is played before the feeder had a chance, and nothing is lost")
        func renderBeforeFeeding() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            // Not settled: there's no audio yet. The engine must not start the clock on its own.
            try rig.renderWithoutFeeding(2048)
            #expect(isSilent(rig.out, in: 0..<2048))
            try await rig.render(4096)
            #expect(rig.deviation(of: .a, from: 0, at: 2048, count: 4096) == 0)
        }

        @Test("a track can start anywhere", arguments: [0.5, 1.0, 2.0, 3.0])
        func startOffset(seconds: Double) async throws {
            let rig = EngineRig()
            let file = RampFile.a
            let first = Int((seconds * file.sampleRate).rounded())
            rig.engine.start(try file.url(), at: seconds)
            try await rig.render(file.frames - first + 3000)
            #expect(rig.deviation(of: file, from: first, at: 0, count: file.frames - first) == 0)
            #expect(isSilent(rig.out, in: (file.frames - first)..<rig.frame))
            #expect(rig.events == ["finished"])
        }

        @Test("tracks shorter than a render slice play too")
        func shortTrack() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.tiny2.url())
            try await rig.render(4096)
            #expect(rig.deviation(of: .tiny2, from: 0, at: 0, count: RampFile.tiny2.frames) == 0)
            #expect(isSilent(rig.out, in: RampFile.tiny2.frames..<4096))
            #expect(rig.events == ["finished"])
        }

        // MARK: Gapless

        @Test("two tracks follow each other without a gap, a click or a lost sample")
        func gapless() async throws {
            let rig = EngineRig()
            let a = RampFile.a, b = RampFile.b
            rig.engine.start(try a.url(), next: try b.url())
            try await rig.render(a.frames + b.frames + 3000)

            #expect(rig.deviation(of: a, from: 0, at: 0, count: a.frames) == 0)
            #expect(rig.deviation(of: b, from: 0, at: a.frames, count: b.frames) == 0)
            #expect(isSilent(rig.out, in: (a.frames + b.frames)..<rig.frame))
            #expect(rig.events == ["advanced", "finished"])
        }

        @Test("tracks that end in the middle of a FLAC block join without padding")
        func noFlacPadding() async throws {
            // 136710 and 110250 frames: neither is a multiple of 4096. AVFoundation's player would insert silence.
            #expect(RampFile.a.frames % 4096 != 0 && RampFile.b.frames % 4096 != 0)
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url(), next: try RampFile.b.url())
            try await rig.render(RampFile.a.frames + 100)
            let boundary = RampFile.a.frames
            #expect(rig.out[0][boundary - 1] == RampFile.a.value(RampFile.a.frames - 1, channel: 0))
            #expect(rig.out[0][boundary] == RampFile.b.value(0, channel: 0))
        }

        @Test("a chain of tracks, each queued when the previous one starts, plays through")
        func chain() async throws {
            let rig = EngineRig()
            let files = [RampFile.a, .b, .c, .b, .a]
            var upcoming = Array(files.dropFirst(2))
            rig.react = { [engine = rig.engine] event in
                guard case .advanced = event, !upcoming.isEmpty else { return }
                engine.setNext(try? upcoming.removeFirst().url())
            }
            rig.engine.start(try files[0].url(), next: try files[1].url())
            try await rig.render(files.reduce(0) { $0 + $1.frames } + 2000)

            var at = 0
            for file in files {
                #expect(rig.deviation(of: file, from: 0, at: at, count: file.frames) == 0, "\(file.name) at \(at)")
                at += file.frames
            }
            #expect(rig.events == ["advanced", "advanced", "advanced", "advanced", "finished"])
        }

        @Test("tracks shorter than two render slices chain gaplessly")
        func shortChain() async throws {
            let rig = EngineRig()
            let files = [RampFile.tiny2, .tiny, .tiny2, .tiny2, .tiny, .tiny2]
            var upcoming = Array(files.dropFirst(2))
            rig.react = { [engine = rig.engine] event in
                guard case .advanced = event, !upcoming.isEmpty else { return }
                engine.setNext(try? upcoming.removeFirst().url())
            }
            rig.engine.start(try files[0].url(), next: try files[1].url())
            try await rig.render(files.reduce(0) { $0 + $1.frames } + 2000)

            var at = 0
            for file in files {
                #expect(rig.deviation(of: file, from: 0, at: at, count: file.frames) == 0, "\(file.name) at \(at)")
                at += file.frames
            }
            #expect(rig.events.last == "finished")
            #expect(rig.events.filter { $0 == "advanced" }.count == files.count - 1)
        }

        @Test("lossless containers of different kinds join exactly")
        func mixedContainers() async throws {
            let rig = EngineRig()
            // The same ramp in AIFF, WAV and ALAC.
            let files = ["a.aiff", "a.wav", "a_alac.m4a"].map { RampFile.a.stored(as: $0) }
            var advances = 0
            rig.react = { [engine = rig.engine] event in
                guard case .advanced = event else { return }
                advances += 1
                if advances == 1 { engine.setNext(try? files[2].url()) }
            }
            rig.engine.start(try files[0].url(), next: try files[1].url())
            try await rig.render(3 * RampFile.a.frames + 2000)
            for n in 0..<3 {
                #expect(rig.deviation(of: .a, from: 0, at: n * RampFile.a.frames, count: RampFile.a.frames) == 0, "part \(n)")
            }
            #expect(rig.events == ["advanced", "advanced", "finished"])
        }

        // MARK: Any rate


        @Test("every file rate plays at every output rate, along the original waveform",
              arguments: [ToneFile.sine44, .sine48, .sine32, .sine96], [44100.0, 48000, 96000])
        func rates(file: ToneFile, outputRate: Double) async throws {
            let rig = EngineRig(rate: outputRate)
            rig.engine.start(try file.url())
            let frames = Int((Double(file.frames) * outputRate / file.sampleRate).rounded())
            try await rig.render(frames + 3000)

            let edge = 64
            let interior = maxDeviation(rig.out, from: edge, count: frames - 2 * edge) { i, c in
                ToneFile.value(at: Double(i + edge) / outputRate, channel: c)
            }
            #expect(interior < 0.0005, "\(file.name) at \(outputRate): \(interior)")
            #expect(isSilent(rig.out, in: (frames + 100)..<rig.frame))
            #expect(rig.events == ["finished"])
        }

        @Test("files of different sample rates follow each other without a click")
        func gaplessAcrossRates() async throws {
            let rig = EngineRig(rate: 44100)
            var advances = 0
            rig.react = { [engine = rig.engine] event in
                guard case .advanced = event else { return }
                advances += 1
                if advances == 1 { engine.setNext(try? ToneFile.sine32.url()) }
            }
            rig.engine.start(try ToneFile.sine44.url(), next: try ToneFile.sine48.url())
            // sine44 is 3 s, sine48 is 2 s, sine32 is 2 s.
            let total: Int = 7 * 44100
            try await rig.render(total + 3000)

            #expect(rig.events == ["advanced", "advanced", "finished"])
            // No step bigger than the sine's own (0.071 per sample at 1 kHz, amplitude 0.5) plus the resampler's
            // start-up error. A discontinuity between the tracks would be a jump of the order of 0.5.
            let step = maxStep(rig.out, in: 0..<total)
            #expect(step < ToneFile.maxStep(rate: 44100) + 0.02, "step \(step)")
            // And no hole: the signal never goes silent for long inside the 7 seconds (a sine crosses zero briefly).
            var longestSilence = 0
            var run = 0
            for i in 0..<total {
                let silent = rig.out[0][i] == 0 && rig.out[1][i] == 0
                run = silent ? run + 1 : 0
                longestSilence = max(longestSilence, run)
            }
            #expect(longestSilence < 4, "silent for \(longestSilence) frames")
        }

        @Test("a 96 kHz 24 bit file plays exactly on a 96 kHz output")
        func hiRes() async throws {
            let rig = EngineRig(rate: 96000)
            let file = RampFile.r96
            rig.engine.start(try file.url())
            try await rig.render(file.frames + 2000)
            #expect(rig.deviation(of: file, from: 0, at: 0, count: file.frames) == 0)
        }

        @Test("mono is played on both channels at full level")
        func mono() async throws {
            let rig = EngineRig(rate: 22050)
            let file = RampFile.mono22
            rig.engine.start(try file.url())
            try await rig.render(file.frames + 2000)
            #expect(rig.deviation(of: file, from: 0, at: 0, count: file.frames) == 0)
        }

        @Test("a 5.1 file is folded down and doesn't clip")
        func surround() async throws {
            let rig = EngineRig()
            let file = RampFile.surround
            rig.engine.start(try file.url())
            try await rig.render(file.frames + 2000)
            #expect(peak(rig.out, in: 0..<file.frames) <= 1.0001)
            #expect(peak(rig.out, in: 0..<file.frames) > 0.3)
            #expect(rig.events == ["finished"])
        }

        @Test("compressed formats play to the end", arguments: ["lossy.mp3", "lossy.m4a", "lossy.ogg"])
        func lossy(name: String) async throws {
            let rig = EngineRig()
            rig.engine.start(try Fixtures.url("playback/" + name))
            try await rig.renderUntilIdle()
            #expect(rig.events == ["finished"])
            let seconds = Double(rig.frame) / 44100
            #expect(abs(seconds - 3) < 0.15, "\(name): ended after \(seconds) s")
            #expect(peak(rig.out, in: 0..<rig.frame) > 0.05)
        }

        // MARK: Position and duration

        @Test("an idle engine has no position and no duration")
        func idle() {
            let rig = EngineRig()
            #expect(rig.engine.position == 0)
            #expect(rig.engine.duration == nil)
            #expect(!rig.engine.isActive)
            #expect(!rig.engine.wantsPlaying)
            #expect(rig.engine.bufferedSeconds == 0)
        }

        @Test("the position follows the playback to the sample")
        func position() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            #expect(rig.engine.position == 0)
            for step in 1...6 {
                try await rig.render(5 * Self.slice)
                let expected = Double(step * 5 * Self.slice) / 44100
                #expect(abs(rig.engine.position - expected) < 1e-9, "after \(step * 5 * Self.slice) frames: \(rig.engine.position)")
            }
        }

        @Test("a track started in the middle reports its position from there")
        func positionOffset() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url(), at: 1.5)
            #expect(rig.engine.position == 1.5)            // before anything was decoded
            try await rig.render(4 * Self.slice)
            #expect(abs(rig.engine.position - (1.5 + Double(4 * Self.slice) / 44100)) < 1e-6)
        }

        @Test("the duration is the exact length of the file")
        func duration() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            #expect(rig.engine.duration == nil)             // not known before the file was opened
            await rig.engine.settle()
            #expect(rig.engine.duration == RampFile.a.duration)
        }

        @Test("the position and duration switch to the next track at the boundary")
        func positionAcrossBoundary() async throws {
            let rig = EngineRig()
            let a = RampFile.a, b = RampFile.b
            rig.engine.start(try a.url(), next: try b.url())
            try await rig.render(a.frames + 4 * Self.slice)
            // The boundary lies inside the 135th slice (a.frames = 133.5 slices); the engine noticed it at its end.
            let into = rig.frame - a.frames
            #expect(abs(rig.engine.position - Double(into) / 44100) < 1e-9)
            #expect(rig.engine.duration == b.duration)
            #expect(rig.events == ["advanced"])
        }

        @Test("the position doesn't run past the end of a track while the next one isn't announced yet")
        func positionClamped() async throws {
            let rig = EngineRig()
            let file = RampFile.tiny
            rig.engine.start(try file.url())
            try await rig.render(file.frames - 100)
            #expect(rig.engine.position <= file.duration + 1e-9)
        }

        // MARK: Lookahead

        @Test("the feeder keeps only the lookahead scheduled, plus the chunk in flight")
        func lookahead() async throws {
            let rig = EngineRig(lookahead: 0.5)
            rig.engine.start(try RampFile.a.url())
            await rig.engine.settle()
            let chunk = Double(TrackDecoder.blockFrames) / 44100
            #expect(rig.engine.bufferedSeconds >= 0.5)
            #expect(rig.engine.bufferedSeconds < 0.5 + chunk + 0.001)
        }

        @Test("with a short lookahead the playback is still exact, across a track boundary too",
              arguments: [PlaybackEngine.renderSlice, 4096, 5000])
        func shortLookahead(step: Int) async throws {
            let rig = EngineRig(lookahead: 0.4)
            let a = RampFile.a, b = RampFile.b
            rig.engine.start(try a.url(), next: try b.url())
            try await rig.render(a.frames + b.frames + 3000, step: step)
            #expect(rig.deviation(of: a, from: 0, at: 0, count: a.frames) == 0)
            #expect(rig.deviation(of: b, from: 0, at: a.frames, count: b.frames) == 0)
            #expect(rig.events == ["advanced", "finished"])
        }

        @Test("if the feeder falls behind, the position doesn't count the silence and the audio goes on where it stopped")
        func starvation() async throws {
            let rig = EngineRig(lookahead: 0.05)
            let file = RampFile.a
            rig.engine.start(try file.url())
            await rig.settle()
            let scheduled = Int((rig.engine.bufferedSeconds * 44100).rounded())
            #expect(scheduled >= 2205 && scheduled <= 2205 + TrackDecoder.blockFrames)

            // Run dry: ten more slices than there is audio.
            let dry = scheduled + 10 * Self.slice
            try await rig.render(dry, settle: false)
            #expect(isSilent(rig.out, in: (scheduled)..<dry))
            #expect(rig.deviation(of: file, from: 0, at: 0, count: scheduled) == 0)

            // The feeder catches up: the audio continues with the next sample, now.
            await rig.settle()
            try await rig.render(4 * Self.slice, settle: false)
            #expect(rig.deviation(of: file, from: scheduled, at: dry, count: 4 * Self.slice) == 0)
            let played = scheduled + 4 * Self.slice
            #expect(abs(rig.engine.position * 44100 - Double(played)) < Double(Self.slice),
                    "position \(rig.engine.position * 44100) vs \(played) frames of audio played")
        }
    }
}
