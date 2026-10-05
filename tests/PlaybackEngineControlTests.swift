// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// Commands given to the engine while it plays: they fade out, act, and fade in again.
    ///
    /// A command given between two `render` calls takes effect at `rig.commitFrame`; a restarted track then begins
    /// exactly there, ramping up over about 25 ms (`fadeInFrames`), and its samples are exact after that.
    @MainActor @Suite("PlaybackEngine: controls")
    struct PlaybackEngineControlTests {
        private static let slice = PlaybackEngine.renderSlice

        /// The biggest step between samples a click-free fade of the test sine may show.
        private var stepLimit: Float { ToneFile.maxStep(rate: 44100) * 1.05 + 0.002 }

        /// A rig playing `file` for `slices` render slices.
        private func playing(_ file: RampFile = .a, next: RampFile? = nil, slices: Int = 10, rate: Double = 44100,
                             lookahead: Double = 60) async throws -> EngineRig {
            let rig = EngineRig(rate: rate, lookahead: lookahead)
            rig.engine.start(try file.url(), next: try next?.url())
            try await rig.render(slices * Self.slice)
            return rig
        }

        private func tonePlaying(slices: Int = 10) async throws -> EngineRig {
            let rig = EngineRig()
            rig.engine.start(try ToneFile.sine44.url())
            try await rig.render(slices * Self.slice)
            return rig
        }

        // MARK: Pause and resume

        @Test("pausing fades the output out, silences it, and freezes the position where the fade ended")
        func pause() async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.pause()
            #expect(!rig.engine.wantsPlaying)
            try await rig.render(6 * Self.slice)

            // Until the command, nothing changed; during the fade it's the same audio, quieter.
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: at) == 0)
            #expect(isSilent(rig.out, in: (at + 1300)..<rig.frame))
            // The player stops at the end of the slice in which the fade completed.
            #expect(abs(rig.engine.position - Double(at + rig.fadeFrames) / 44100) < 1e-9)
            #expect(rig.engine.isActive)
            #expect(rig.events.isEmpty)

            // Frozen while paused.
            let frozen = rig.engine.position
            try await rig.render(5 * Self.slice)
            #expect(rig.engine.position == frozen)
        }

        @Test("the fade-out follows the music: no click")
        func pauseNoClick() async throws {
            let rig = try await tonePlaying()
            let at = rig.frame
            rig.engine.pause()
            try await rig.render(4 * Self.slice)
            #expect(maxStep(rig.out, in: (at - 100)..<rig.frame) <= stepLimit)
            // It does get quieter, all the way to nothing (the ramp takes about 25 ms = 1100 frames).
            #expect(peak(rig.out, in: (at + 1000)..<(at + 1100)) < peak(rig.out, in: (at - 1100)..<at) * 0.15)
            #expect(isSilent(rig.out, in: (at + 1300)..<rig.frame))
        }

        @Test("resuming continues with the very next sample, faded in")
        func resume() async throws {
            let rig = try await playing()
            rig.engine.pause()
            try await rig.render(6 * Self.slice)
            let paused = Int((rig.engine.position * 44100).rounded())
            #expect(paused > 0)

            let at = rig.frame
            rig.engine.resume()
            #expect(rig.engine.wantsPlaying)
            try await rig.render(6 * Self.slice)

            #expect(isSilent(rig.out, in: (at - 2 * Self.slice)..<at))
            // From the end of the fade-in on, the audio is exactly what follows the pause position.
            let settled = at + rig.fadeInFrames
            #expect(rig.deviation(of: .a, from: paused + rig.fadeInFrames, at: settled, count: 6 * Self.slice - rig.fadeInFrames) == 0)
            // And the fade-in is a ramp, not a jump.
            #expect(abs(rig.out[0][at]) < 0.05)
            #expect(abs(rig.engine.position * 44100 - Double(paused + 6 * Self.slice)) < 1)
        }

        @Test("the fade-in doesn't click")
        func resumeNoClick() async throws {
            let rig = try await tonePlaying()
            rig.engine.pause()
            try await rig.render(4 * Self.slice)
            let at = rig.frame
            rig.engine.resume()
            try await rig.render(4 * Self.slice)
            #expect(maxStep(rig.out, in: (at - 10)..<rig.frame) <= stepLimit)
        }

        @Test("pause followed at once by resume turns the fade around: no stop, no lost or repeated sample")
        func pauseResumeQuickly() async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.pause()
            try await rig.render(Self.slice)               // half way through the fade-out
            rig.engine.resume()
            try await rig.render(8 * Self.slice)

            // Never silent for long (it dipped, it didn't stop) and the content is continuous.
            let end = rig.frame
            #expect(rig.deviation(of: .a, from: end - 4 * Self.slice, at: end - 4 * Self.slice, count: 4 * Self.slice) == 0)
            #expect(rig.soundFrames(in: at..<end) > (end - at) - 200)
            #expect(rig.engine.wantsPlaying)
            #expect(abs(rig.engine.position * 44100 - Double(end)) < 1)
        }

        @Test("pausing twice, or resuming a playing track, changes nothing")
        func idempotent() async throws {
            let rig = try await playing()
            rig.engine.resume()                          // already playing
            try await rig.render(4 * Self.slice)
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: rig.frame) == 0)

            rig.engine.pause()
            rig.engine.pause()
            try await rig.render(4 * Self.slice)
            let position = rig.engine.position
            rig.engine.pause()
            try await rig.render(2 * Self.slice)
            #expect(rig.engine.position == position)
            rig.engine.resume()
            rig.engine.resume()
            try await rig.render(6 * Self.slice)
            #expect(rig.engine.position > position)
        }

        @Test("pausing before the first audio is ready keeps the track from starting")
        func pauseWhileStarting() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            rig.engine.pause()
            try await rig.render(4 * Self.slice)
            #expect(isSilent(rig.out, in: 0..<rig.frame))
            #expect(rig.engine.position == 0)
            #expect(rig.engine.isActive)

            let at = rig.frame
            rig.engine.resume()
            try await rig.render(4 * Self.slice)
            // Never faded out, so exact from the first sample.
            #expect(rig.deviation(of: .a, from: 0, at: at, count: 4 * Self.slice) == 0)
        }

        @Test("a track can be started paused")
        func startPaused() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url(), at: 1, playing: false)
            try await rig.render(3 * Self.slice)
            #expect(isSilent(rig.out, in: 0..<rig.frame))
            #expect(rig.engine.position == 1)
            rig.engine.resume()
            try await rig.render(3 * Self.slice)
            #expect(rig.deviation(of: .a, from: 44100, at: 3 * Self.slice, count: 3 * Self.slice) == 0)
        }

        @Test("pause, resume and stop on an idle engine are harmless")
        func idleCommands() async throws {
            let rig = EngineRig()
            rig.engine.pause()
            rig.engine.resume()
            rig.engine.seek(to: 3)
            rig.engine.setNext(try RampFile.b.url())
            rig.engine.stop()
            try await rig.render(2 * Self.slice)
            #expect(isSilent(rig.out, in: 0..<rig.frame))
            #expect(!rig.engine.isActive && rig.events.isEmpty)
        }

        // MARK: Seeking

        @Test("seeking while playing continues from the target, exactly, after the fade-in", arguments: [0.0, 0.7, 2.0, 2.9])
        func seek(seconds: Double) async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.seek(to: seconds)
            #expect(rig.engine.position == seconds)       // shown at once
            try await rig.render(8 * Self.slice)

            let commit = at + rig.fadeFrames
            let target = Int((seconds * 44100).rounded())
            // Up to the command: unchanged. After the fade-out: the new place.
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: at) == 0)
            let settled = commit + rig.fadeInFrames
            #expect(rig.deviation(of: .a, from: target + rig.fadeInFrames, at: settled, count: rig.frame - settled) == 0)
            #expect(abs(rig.engine.position * 44100 - Double(target + rig.frame - commit)) < 1)
            #expect(rig.events.isEmpty)
        }

        @Test("seeking doesn't click, neither the fade-out nor the fade-in")
        func seekNoClick() async throws {
            let rig = try await tonePlaying()
            let at = rig.frame
            rig.engine.seek(to: 1.2345)
            try await rig.render(8 * Self.slice)
            #expect(maxStep(rig.out, in: (at - 10)..<rig.frame) <= stepLimit)
        }

        @Test("a seek far past the end goes to the last frame, and the track ends right after it")
        func seekPastEnd() async throws {
            let rig = try await playing()
            rig.engine.seek(to: 10_000)
            #expect(abs(rig.engine.position - (RampFile.a.duration - 1 / 44100)) < 1e-9)
            try await rig.render(6 * Self.slice)
            #expect(rig.events == ["finished"])
            #expect(!rig.engine.isActive)
        }

        @Test("a negative seek means the beginning")
        func seekNegative() async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.seek(to: -3)
            try await rig.render(8 * Self.slice)
            let settled = at + rig.fadeFrames + rig.fadeInFrames
            #expect(rig.deviation(of: .a, from: rig.fadeInFrames, at: settled, count: rig.frame - settled) == 0)
        }

        @Test("seeking a paused track moves it without a sound, and playing goes on from there")
        func seekPaused() async throws {
            let rig = try await playing()
            rig.engine.pause()
            try await rig.render(5 * Self.slice)
            rig.engine.seek(to: 1.5)
            #expect(rig.engine.position == 1.5)
            try await rig.render(4 * Self.slice)
            #expect(rig.engine.position == 1.5)
            #expect(isSilent(rig.out, in: (rig.frame - 4 * Self.slice)..<rig.frame))

            let at = rig.frame
            rig.engine.resume()
            try await rig.render(6 * Self.slice)
            let first = Int((1.5 * 44100).rounded())
            #expect(rig.deviation(of: .a, from: first + rig.fadeInFrames, at: at + rig.fadeInFrames,
                                  count: 6 * Self.slice - rig.fadeInFrames) == 0)
        }

        @Test("many seeks in a row: the last one counts")
        func seekMash() async throws {
            let rig = try await playing()
            let at = rig.frame
            for s in [0.5, 1.0, 1.5, 0.2, 2.2] { rig.engine.seek(to: s) }
            #expect(rig.engine.position == 2.2)
            try await rig.render(8 * Self.slice)
            let settled = at + rig.fadeFrames + rig.fadeInFrames
            let target = Int((2.2 * 44100).rounded())
            #expect(rig.deviation(of: .a, from: target + rig.fadeInFrames, at: settled, count: rig.frame - settled) == 0)
        }

        @Test("a seek keeps the next track queued: it still follows gaplessly")
        func seekKeepsNext() async throws {
            let rig = try await playing(next: .b)
            let at = rig.frame
            let target = RampFile.a.frames - 20_000
            rig.engine.seek(to: Double(target) / 44100)
            try await rig.render(20_000 + RampFile.b.frames + 3 * Self.slice)

            let commit = at + rig.fadeFrames
            let boundary = commit + 20_000
            #expect(rig.deviation(of: .a, from: target + rig.fadeInFrames, at: commit + rig.fadeInFrames,
                                  count: 20_000 - rig.fadeInFrames) == 0)
            #expect(rig.deviation(of: .b, from: 0, at: boundary, count: RampFile.b.frames) == 0)
            #expect(rig.events == ["advanced", "finished"])
        }

        @Test("seeking within the last frames, then nothing else queued, ends the track right there")
        func seekNearEnd() async throws {
            let rig = try await playing()
            rig.engine.seek(to: RampFile.a.duration - 0.01)
            try await rig.render(10 * Self.slice)
            #expect(rig.events == ["finished"])
        }

        // MARK: Stop

        @Test("stopping fades out, then nothing plays and nothing is left loaded")
        func stop() async throws {
            let rig = try await tonePlaying()
            let at = rig.frame
            rig.engine.stop()
            #expect(!rig.engine.isActive)
            #expect(rig.engine.position == 0)
            try await rig.render(6 * Self.slice)
            #expect(maxStep(rig.out, in: (at - 10)..<rig.frame) <= stepLimit)
            #expect(isSilent(rig.out, in: (at + 1300)..<rig.frame))
            #expect(rig.events.isEmpty)          // stopping is not "finished"
            #expect(rig.engine.duration == nil)
        }

        @Test("stopping twice, or a command after stopping, does nothing")
        func stopTwice() async throws {
            let rig = try await playing()
            rig.engine.stop()
            rig.engine.stop()
            rig.engine.resume()
            rig.engine.pause()
            rig.engine.seek(to: 1)
            rig.engine.setNext(try RampFile.b.url())
            try await rig.render(6 * Self.slice)
            #expect(isSilent(rig.out, in: (rig.frame - 4 * Self.slice)..<rig.frame))
            #expect(!rig.engine.isActive)
            #expect(rig.events.isEmpty)
        }

        @Test("stopping before the track ever played")
        func stopWhileStarting() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            rig.engine.stop()
            try await rig.render(4 * Self.slice)
            #expect(isSilent(rig.out, in: 0..<rig.frame))
            #expect(!rig.engine.isActive && rig.events.isEmpty)
        }

        @Test("a paused track can be stopped")
        func stopPaused() async throws {
            let rig = try await playing()
            rig.engine.pause()
            try await rig.render(5 * Self.slice)
            rig.engine.stop()
            #expect(!rig.engine.isActive)
            try await rig.render(2 * Self.slice)
            #expect(rig.engine.position == 0)
        }

        @Test("after a stop, playing again works, from the first sample")
        func restartAfterStop() async throws {
            let rig = try await playing()
            rig.engine.stop()
            try await rig.render(4 * Self.slice)
            let at = rig.frame
            rig.engine.start(try RampFile.b.url())
            try await rig.render(6 * Self.slice)
            #expect(rig.deviation(of: .b, from: rig.fadeInFrames, at: at + rig.fadeInFrames, count: 6 * Self.slice - rig.fadeInFrames) == 0)
            #expect(abs(rig.engine.position * 44100 - Double(6 * Self.slice)) < 1)
        }

        @Test("playing again after the queue ran out works, exactly")
        func restartAfterFinish() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.tiny.url())
            try await rig.render(4 * Self.slice)
            #expect(rig.events == ["finished"])
            let at = rig.frame
            rig.engine.start(try RampFile.b.url())
            try await rig.render(4 * Self.slice)
            #expect(rig.deviation(of: .b, from: 0, at: at, count: 4 * Self.slice) == 0)
        }

        // MARK: Replacing what plays

        @Test("starting another track fades the old one out and plays the new one from its first sample")
        func replace() async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.start(try RampFile.b.url())
            try await rig.render(8 * Self.slice)
            let commit = at + rig.fadeFrames
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: at) == 0)
            #expect(rig.deviation(of: .b, from: rig.fadeInFrames, at: commit + rig.fadeInFrames, count: rig.frame - commit - rig.fadeInFrames) == 0)
            #expect(rig.events.isEmpty)
        }

        @Test("replacing a track doesn't click, even between files of different rates")
        func replaceNoClick() async throws {
            let rig = try await tonePlaying()
            let at = rig.frame
            rig.engine.start(try ToneFile.sine48.url(), at: 0.3)
            try await rig.render(8 * Self.slice)
            #expect(maxStep(rig.out, in: (at - 10)..<rig.frame) <= stepLimit)
        }

        @Test("starting several tracks before anything was heard: only the last one plays, from its first sample")
        func startMash() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            rig.engine.start(try RampFile.b.url(), next: try RampFile.a.url())
            rig.engine.start(try RampFile.c.url())
            try await rig.render(6 * Self.slice)
            #expect(rig.deviation(of: .c, from: 0, at: 0, count: 6 * Self.slice) == 0)
            #expect(rig.events.isEmpty)
            #expect(rig.engine.duration == RampFile.c.duration)
        }

        @Test("starting while a fade-out is running: the last request wins and the fade isn't extended")
        func startDuringFade() async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.start(try RampFile.b.url())
            try await rig.render(Self.slice)
            rig.engine.start(try RampFile.c.url())
            try await rig.render(8 * Self.slice)
            let commit = at + rig.fadeFrames
            let settled = commit + rig.fadeInFrames
            #expect(rig.deviation(of: .c, from: rig.fadeInFrames, at: settled, count: rig.frame - settled) == 0)
        }

        @Test("starting the same track again restarts it")
        func restartSame() async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.start(try RampFile.a.url())
            try await rig.render(8 * Self.slice)
            let settled = at + rig.fadeFrames + rig.fadeInFrames
            #expect(rig.deviation(of: .a, from: rig.fadeInFrames, at: settled, count: rig.frame - settled) == 0)
        }

        // MARK: The order of commands doesn't matter, the final intent does

        @Test("pause, seek, resume: plays from the target")
        func pauseSeekResume() async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.pause()
            rig.engine.seek(to: 1.0)
            rig.engine.resume()
            try await rig.render(8 * Self.slice)
            let settled = at + rig.fadeFrames + rig.fadeInFrames
            #expect(rig.deviation(of: .a, from: 44100 + rig.fadeInFrames, at: settled, count: rig.frame - settled) == 0)
            #expect(rig.engine.wantsPlaying)
        }

        @Test("seek, then pause: paused at the target")
        func seekPause() async throws {
            let rig = try await playing()
            rig.engine.seek(to: 1.0)
            rig.engine.pause()
            try await rig.render(8 * Self.slice)
            #expect(rig.engine.position == 1.0)
            #expect(isSilent(rig.out, in: (rig.frame - 4 * Self.slice)..<rig.frame))
        }

        @Test("pause, then start: starting means playing")
        func pauseStart() async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.pause()
            rig.engine.start(try RampFile.b.url())
            try await rig.render(8 * Self.slice)
            let settled = at + rig.fadeFrames + rig.fadeInFrames
            #expect(rig.deviation(of: .b, from: rig.fadeInFrames, at: settled, count: rig.frame - settled) == 0)
        }

        @Test("seek, then stop: stopped")
        func seekStop() async throws {
            let rig = try await playing()
            rig.engine.seek(to: 1.0)
            rig.engine.stop()
            try await rig.render(8 * Self.slice)
            #expect(!rig.engine.isActive)
            #expect(isSilent(rig.out, in: (rig.frame - 4 * Self.slice)..<rig.frame))
        }

        @Test("stop, then start: plays the new track")
        func stopStart() async throws {
            let rig = try await playing()
            let at = rig.frame
            rig.engine.stop()
            rig.engine.start(try RampFile.b.url())
            try await rig.render(8 * Self.slice)
            let settled = at + rig.fadeFrames + rig.fadeInFrames
            #expect(rig.engine.isActive)
            #expect(rig.deviation(of: .b, from: rig.fadeInFrames, at: settled, count: rig.frame - settled) == 0)
        }

        // MARK: The queue

        @Test("without a next track the engine finishes after the current one")
        func noNext() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            try await rig.render(RampFile.a.frames + 2 * Self.slice)
            #expect(rig.events == ["finished"])
        }

        @Test("queuing the same next track again changes nothing")
        func sameNext() async throws {
            let rig = try await playing(next: .b)
            rig.engine.setNext(try RampFile.b.url())
            try await rig.render(RampFile.a.frames + RampFile.b.frames)
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
            #expect(rig.deviation(of: .b, from: 0, at: RampFile.a.frames, count: RampFile.b.frames) == 0)
        }

        @Test("a next track queued late (the current one is nearly over) still follows without a gap")
        func lateNext() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            try await rig.render(RampFile.a.frames - 3000)
            rig.engine.setNext(try RampFile.b.url())
            try await rig.render(3000 + RampFile.b.frames + 2000)
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
            #expect(rig.deviation(of: .b, from: 0, at: RampFile.a.frames, count: RampFile.b.frames) == 0)
            #expect(rig.events == ["advanced", "finished"])
        }

        @Test("replacing the next track before any of it was scheduled needs no restart: the audio stays exact")
        func replaceNextEarly() async throws {
            let rig = EngineRig(lookahead: 0.4)
            let a = RampFile.a
            rig.engine.start(try a.url(), next: try RampFile.b.url())
            try await rig.render(5 * Self.slice)
            rig.engine.setNext(try RampFile.c.url())
            try await rig.render(a.frames + RampFile.c.frames)
            #expect(rig.deviation(of: a, from: 0, at: 0, count: a.frames) == 0)
            #expect(rig.deviation(of: .c, from: 0, at: a.frames, count: RampFile.c.frames) == 0)
        }

        @Test("replacing the next track after its audio was already scheduled: the current one carries on from where it is")
        func replaceNextLate() async throws {
            let rig = try await playing(next: .b)       // lookahead 60 s: b is in the player's queue
            let at = rig.frame
            rig.engine.setNext(try RampFile.c.url())
            try await rig.render(RampFile.a.frames + RampFile.c.frames)

            let commit = at + rig.fadeFrames
            // a goes on from the position the fade ended at, with a fade-in, and then c follows a's end.
            let resumeFrom = commit
            let settled = commit + rig.fadeInFrames
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: at) == 0)
            #expect(rig.deviation(of: .a, from: resumeFrom + rig.fadeInFrames, at: settled, count: RampFile.a.frames - resumeFrom - rig.fadeInFrames) == 0)
            let boundary = commit + (RampFile.a.frames - resumeFrom)
            #expect(rig.deviation(of: .c, from: 0, at: boundary, count: RampFile.c.frames) == 0)
            #expect(rig.events == ["advanced", "finished"])
        }

        @Test("removing the next track after its audio was scheduled: the current one ends the playback")
        func removeNextLate() async throws {
            let rig = try await playing(next: .b)
            let at = rig.frame
            rig.engine.setNext(nil)
            try await rig.render(RampFile.a.frames + RampFile.b.frames)
            let commit = at + rig.fadeFrames
            #expect(rig.events == ["finished"])
            // After a's end there is silence: b was never heard.
            let end = commit + (RampFile.a.frames - commit)
            #expect(isSilent(rig.out, in: (end + 100)..<rig.frame))
        }

        @Test("queuing a track while a seek is in progress applies to the restarted playback")
        func nextDuringSeek() async throws {
            let rig = try await playing()
            let at = rig.frame
            let target = RampFile.a.frames - 10_000
            rig.engine.seek(to: Double(target) / 44100)
            rig.engine.setNext(try RampFile.c.url())
            try await rig.render(10_000 + RampFile.c.frames + 3 * Self.slice)
            let boundary = at + rig.fadeFrames + 10_000
            #expect(rig.deviation(of: .c, from: 0, at: boundary, count: RampFile.c.frames) == 0)
            #expect(rig.events == ["advanced", "finished"])
        }

        // MARK: Volume

        @Test("the volume scales the output")
        func volume() async throws {
            let rig = EngineRig()
            rig.engine.volume = 0.5
            rig.engine.start(try RampFile.a.url())
            try await rig.render(8 * Self.slice)
            let d = maxDeviation(rig.out, from: 4 * Self.slice, count: 4 * Self.slice) {
                RampFile.a.value(4 * Self.slice + $0, channel: $1) * 0.5
            }
            #expect(d < 1e-6, "deviation \(d)")
        }

        @Test("volume 0 is silence, and it can be raised while playing")
        func volumeZero() async throws {
            let rig = EngineRig()
            rig.engine.volume = 0
            rig.engine.start(try RampFile.a.url())
            try await rig.render(4 * Self.slice)
            #expect(isSilent(rig.out, in: (2 * Self.slice)..<rig.frame))   // after the ramp down from the initial 1
            rig.engine.volume = 1
            try await rig.render(12 * Self.slice)
            // The mixer's volume ramp is slower than the node's (up to about 70 ms); give it twice that.
            let from = 4 * Self.slice + 6144
            #expect(rig.deviation(of: .a, from: from, at: from, count: rig.frame - from) < 1e-6)
        }

        @Test("changing the volume doesn't click")
        func volumeNoClick() async throws {
            let rig = try await tonePlaying()
            let at = rig.frame
            rig.engine.volume = 0.1
            try await rig.render(4 * Self.slice)
            rig.engine.volume = 1
            try await rig.render(4 * Self.slice)
            #expect(maxStep(rig.out, in: (at - 10)..<rig.frame) <= stepLimit)
        }

        @Test("out-of-range volumes are limited to 0...1")
        func volumeClamped() async throws {
            let rig = EngineRig()
            rig.engine.volume = 3
            rig.engine.start(try RampFile.a.url())
            try await rig.render(4 * Self.slice)
            #expect(peak(rig.out, in: 0..<rig.frame) <= 1.0)
            rig.engine.volume = -2
            try await rig.render(8 * Self.slice)
            #expect(isSilent(rig.out, in: (rig.frame - 2 * Self.slice)..<rig.frame))
        }

        @Test("the volume stays across tracks, pauses and seeks")
        func volumeKept() async throws {
            let rig = EngineRig()
            rig.engine.volume = 0.25
            rig.engine.start(try RampFile.tiny.url(), next: try RampFile.b.url())
            try await rig.render(6 * Self.slice)
            // b follows tiny, so output frame i holds b's frame i - tiny.frames.
            let shift = 4 * Self.slice - RampFile.tiny.frames
            let scaled = maxDeviation(rig.out, from: 4 * Self.slice, count: 2 * Self.slice) {
                RampFile.b.value(shift + $0, channel: $1) * 0.25
            }
            #expect(scaled < 1e-6)
            rig.engine.pause()
            try await rig.render(4 * Self.slice)
            rig.engine.resume()
            rig.engine.seek(to: 1)
            try await rig.render(6 * Self.slice)
            #expect(peak(rig.out, in: (rig.frame - 2 * Self.slice)..<rig.frame) <= 0.25 + 1e-6)
        }

        // MARK: Other rates

        @Test("controls work at other output rates: positions are in seconds", arguments: [48000.0, 96000, 22050])
        func otherRates(rate: Double) async throws {
            let rig = EngineRig(rate: rate)
            rig.engine.start(try ToneFile.sine44.url())
            try await rig.render(Int(rate))        // one second
            #expect(abs(rig.engine.position - 1.0) < 0.03)
            #expect(abs((rig.engine.duration ?? 0) - 3.0) < 1e-6)

            rig.engine.pause()
            try await rig.render(Int(rate / 2))
            let paused = rig.engine.position
            #expect(paused > 1.0 && paused < 1.2)

            rig.engine.seek(to: 2.0)
            rig.engine.resume()
            try await rig.render(Int(rate / 2))
            #expect(abs(rig.engine.position - 2.5) < 0.1, "position \(rig.engine.position)")
        }
    }
}
