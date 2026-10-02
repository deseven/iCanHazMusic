import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// Tracks that can't be played, as the current or as the next one.
    @MainActor @Suite("PlaybackEngine: failures")
    struct PlaybackEngineFailureTests {
        private static let slice = PlaybackEngine.renderSlice

        private let missing = URL(fileURLWithPath: "/nonexistent/missing.flac")

        private func broken(_ name: String) throws -> URL { try Fixtures.url("broken/" + name) }

        // MARK: Current track

        @Test("a missing file as the current track: reported, nothing plays, the engine is idle")
        func missingCurrent() async throws {
            let rig = EngineRig()
            rig.engine.start(missing)
            try await rig.render(4 * Self.slice)
            #expect(rig.events == ["failed:missing.flac:current"])
            #expect(!rig.engine.isActive)
            #expect(isSilent(rig.out, in: 0..<rig.frame))
            #expect(rig.engine.position == 0 && rig.engine.duration == nil)
        }

        @Test("a damaged file as the current track is reported the same way", arguments: ["garbage.mp3", "empty.flac"])
        func brokenCurrent(name: String) async throws {
            let rig = EngineRig()
            rig.engine.start(try broken(name))
            try await rig.render(4 * Self.slice)
            #expect(rig.events == ["failed:\(name):current"])
            #expect(!rig.engine.isActive)
        }

        @Test("the track queued behind a failed current one is not played by the engine: the listener decides")
        func nextAfterFailedCurrent() async throws {
            let rig = EngineRig()
            rig.engine.start(missing, next: try RampFile.b.url())
            try await rig.render(4 * Self.slice)
            #expect(rig.events == ["failed:missing.flac:current"])
            #expect(isSilent(rig.out, in: 0..<rig.frame))
        }

        @Test("a listener that reacts to the failure by starting another track gets it played from the first sample")
        func recoverFromCurrent() async throws {
            let rig = EngineRig()
            rig.react = { [engine = rig.engine] event in
                if case .failed(_, true, _) = event { engine.start((try? RampFile.b.url())!) }
            }
            rig.engine.start(missing)
            try await rig.render(6 * Self.slice)
            #expect(rig.deviation(of: .b, from: 0, at: 0, count: 6 * Self.slice) == 0)
            #expect(rig.engine.isActive)
        }

        @Test("a failure while a track is playing (restart on a broken file) ends playback")
        func failDuringPlayback() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            try await rig.render(4 * Self.slice)
            rig.engine.start(missing)
            try await rig.render(8 * Self.slice)
            #expect(rig.events == ["failed:missing.flac:current"])
            #expect(!rig.engine.isActive)
            #expect(isSilent(rig.out, in: (rig.frame - 4 * Self.slice)..<rig.frame))
        }

        // MARK: Next track

        @Test("a missing next track is reported while the current one plays on; the playback then ends after it")
        func missingNext() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url(), next: missing)
            try await rig.render(RampFile.a.frames + 3000)
            #expect(rig.events == ["failed:missing.flac:next", "finished"])
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
            #expect(isSilent(rig.out, in: RampFile.a.frames..<rig.frame))
        }

        @Test("a damaged next track is skipped the same way", arguments: ["garbage.mp3", "empty.flac"])
        func brokenNext(name: String) async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url(), next: try broken(name))
            try await rig.render(RampFile.a.frames + 3000)
            #expect(rig.events == ["failed:\(name):next", "finished"])
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
        }

        @Test("a replacement queued after the failure plays gaplessly behind the current track")
        func replaceFailedNext() async throws {
            let rig = EngineRig()
            rig.react = { [engine = rig.engine] event in
                if case .failed(_, false, _) = event { engine.setNext(try? RampFile.c.url()) }
            }
            rig.engine.start(try RampFile.a.url(), next: missing)
            try await rig.render(RampFile.a.frames + RampFile.c.frames + 3000)
            #expect(rig.events == ["failed:missing.flac:next", "advanced", "finished"])
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
            #expect(rig.deviation(of: .c, from: 0, at: RampFile.a.frames, count: RampFile.c.frames) == 0)
        }

        @Test("a missing track in the middle of a chain: reported, the chain goes on with what is queued after it")
        func chainWithHole() async throws {
            let rig = EngineRig()
            let queue: [URL?] = [try RampFile.b.url(), missing, try RampFile.c.url()]
            var upcoming = Array(queue.dropFirst(1))
            rig.react = { [engine = rig.engine] event in
                switch event {
                case .advanced, .failed(_, false, _):
                    if !upcoming.isEmpty { engine.setNext(upcoming.removeFirst()) }
                default: break
                }
            }
            rig.engine.start(try RampFile.a.url(), next: queue[0])
            try await rig.render(RampFile.a.frames + RampFile.b.frames + RampFile.c.frames + 4000)
            #expect(rig.events.filter { $0.hasPrefix("failed") } == ["failed:missing.flac:next"])
            #expect(rig.events.last == "finished")
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
            #expect(rig.deviation(of: .b, from: 0, at: RampFile.a.frames, count: RampFile.b.frames) == 0)
            let cAt = RampFile.a.frames + RampFile.b.frames
            #expect(rig.deviation(of: .c, from: 0, at: cAt, count: RampFile.c.frames) == 0)
        }

        @Test("a missing next track queued late is reported too")
        func lateMissingNext() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url())
            try await rig.render(RampFile.a.frames - 5000)
            rig.engine.setNext(missing)
            try await rig.render(10_000)
            #expect(rig.events == ["failed:missing.flac:next", "finished"])
        }

        @Test("a failure of the next track after a seek is reported once, not for the dropped queue")
        func failureAfterSeek() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.a.url(), next: missing)
            try await rig.render(4 * Self.slice)
            rig.engine.seek(to: 1)
            try await rig.render(2 * RampFile.a.frames)
            #expect(rig.events.filter { $0 == "failed:missing.flac:next" }.count >= 1)
            #expect(rig.events.last == "finished")
        }

        // MARK: Files that end early

        @Test("a cut-short file plays what is there and ends, without a failure")
        func truncatedCurrent() async throws {
            let rig = EngineRig()
            rig.engine.start(try Fixtures.url("playback/truncated.flac"))
            try await rig.renderUntilIdle()
            #expect(rig.events == ["finished"])
            let heard = rig.soundFrames(in: 0..<rig.frame)
            #expect(heard > 1000 && heard < RampFile.a.frames)
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: heard) == 0)
        }

        @Test("a cut-short file as the next track: the join is still gapless, the end comes where the data ends")
        func truncatedNext() async throws {
            let rig = EngineRig()
            rig.engine.start(try RampFile.b.url(), next: try Fixtures.url("playback/truncated.flac"))
            try await rig.render(RampFile.b.frames + 3000)
            try await rig.renderUntilIdle()
            #expect(rig.events == ["advanced", "finished"])
            #expect(rig.deviation(of: .b, from: 0, at: 0, count: RampFile.b.frames) == 0)
            let heard = rig.soundFrames(in: RampFile.b.frames..<rig.frame)
            #expect(heard > 1000 && heard < RampFile.a.frames)
            #expect(rig.deviation(of: .a, from: 0, at: RampFile.b.frames, count: heard) == 0)
        }

        // MARK: Misc

        @Test("the engine can be used again after any failure")
        func usableAfterFailure() async throws {
            let rig = EngineRig()
            rig.engine.start(missing)
            try await rig.render(3 * Self.slice)
            rig.engine.start(try broken("garbage.mp3"))
            try await rig.render(3 * Self.slice)
            let at = rig.frame
            rig.engine.start(try RampFile.a.url())
            try await rig.render(RampFile.a.frames + 2000)
            #expect(rig.deviation(of: .a, from: 0, at: at, count: RampFile.a.frames) == 0)
            #expect(rig.events == ["failed:missing.flac:current", "failed:garbage.mp3:current", "finished"])
        }

        @Test("many failures in a row don't wedge anything")
        func failureStorm() async throws {
            let rig = EngineRig()
            var left = 20
            rig.react = { [engine = rig.engine, missing] event in
                if case .failed(_, true, _) = event, left > 0 {
                    left -= 1
                    engine.start(left == 0 ? (try? RampFile.tiny.url())! : missing)
                }
            }
            rig.engine.start(missing)
            try await rig.render(8 * Self.slice)
            #expect(rig.events.filter { $0.hasPrefix("failed") }.count == 20)
            #expect(rig.events.last == "finished")
        }
    }
}
