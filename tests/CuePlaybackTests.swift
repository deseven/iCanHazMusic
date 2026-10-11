// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// Playing tracks that are parts of a file: the decoder, the engine (offline), the waveform and the playlist logic.
    ///
    /// `RampFile.a` is 136 710 frames at 44.1 kHz; the parts used here are `[1.0, 2.4)` (frames 44 100 ..< 105 840) and
    /// the rest of the file after 2.4 s.
    @MainActor @Suite("CUE playback")
    struct CuePlaybackTests {
        private static let slice = PlaybackEngine.renderSlice
        private static let a = RampFile.a
        private static let middleStart = 44_100
        private static let middleEnd = 105_840
        private static var middleFrames: Int { middleEnd - middleStart }

        private func source(_ file: RampFile = .a, from start: Double, to end: Double?) throws -> PlaybackSource {
            PlaybackSource(url: try file.url(), start: start, end: end)
        }

        private func middle() throws -> PlaybackSource { try source(from: 1.0, to: 2.4) }

        // MARK: - The decoder

        private func decode(_ url: URL, from start: Double, to end: Double?, rate: Double = 44100,
                            isPart: Bool = false) async -> (samples: [[Float]], failure: String?, warning: String?) {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
            let decoder = TrackDecoder(url: url, startSeconds: start, endSeconds: end, isPart: isPart, outputFormat: format)
            var samples: [[Float]] = [[], []]
            while true {
                switch await decoder.next() {
                case .chunk(let chunk):
                    for channel in 0..<2 {
                        samples[channel].append(contentsOf: UnsafeBufferPointer(
                            start: chunk.buffer.floatChannelData![channel], count: Int(chunk.buffer.frameLength)))
                    }
                case .finished(let warning): return (samples, nil, warning)
                case .failed(let message): return (samples, message, nil)
                }
            }
        }

        @Test("the decoder delivers exactly the frames between start and end")
        func decoderPart() async throws {
            let d = await decode(try Self.a.url(), from: 1.0, to: 2.4)
            #expect(d.failure == nil && d.warning == nil)
            #expect(d.samples.frameCount == Self.middleFrames)
            #expect(maxDeviation(d.samples, from: 0, count: Self.middleFrames) { Self.a.value(Self.middleStart + $0, channel: $1) } == 0)
        }

        @Test("without an end the part runs to the end of the file")
        func decoderOpenEnd() async throws {
            let d = await decode(try Self.a.url(), from: 2.4, to: nil, isPart: true)
            #expect(d.failure == nil)
            #expect(d.samples.frameCount == Self.a.frames - Self.middleEnd)
            #expect(maxDeviation(d.samples, from: 0, count: d.samples.frameCount) { Self.a.value(Self.middleEnd + $0, channel: $1) } == 0)
        }

        @Test("an end past the end of the file is the end of the file")
        func decoderEndPastFile() async throws {
            let d = await decode(try Self.a.url(), from: 2.4, to: 99)
            #expect(d.failure == nil && d.warning == nil)
            #expect(d.samples.frameCount == Self.a.frames - Self.middleEnd)
        }

        @Test("a part that isn't in the file fails, where a whole file would play its last frame",
              arguments: [(10.0, 12.0 as Double?), (3.2, nil), (1.0, 1.0), (2.0, 1.0), (4.0, 3.0)])
        func decoderBeyond(start: Double, end: Double?) async throws {
            let part = await decode(try Self.a.url(), from: start, to: end, isPart: true)
            #expect(part.failure?.contains("beyond") == true, "\(start)–\(String(describing: end))")
            #expect(part.samples.frameCount == 0)
        }

        @Test("a part of a file at another rate is resampled to exactly its length")
        func decoderResampled() async throws {
            // r48: 96 000 frames at 48 kHz. 0.5 s ... 1.5 s is 48 000 frames, which are 44 100 at 44.1 kHz.
            let d = await decode(try RampFile.r48.url(), from: 0.5, to: 1.5)
            #expect(d.failure == nil)
            #expect(d.samples.frameCount == 44_100)
        }

        @Test("the end counts from the start of the file, whatever the start is: positions of a seek inside a part")
        func decoderStartInsidePart() async throws {
            let d = await decode(try Self.a.url(), from: 1.5, to: 2.4)
            #expect(d.samples.frameCount == Self.middleEnd - 66_150)
            #expect(maxDeviation(d.samples, from: 0, count: d.samples.frameCount) { Self.a.value(66_150 + $0, channel: $1) } == 0)
        }

        // MARK: - The engine

        @Test("a part plays exactly its samples, then the engine reports the end")
        func playsThePart() async throws {
            let rig = EngineRig()
            rig.engine.start(try middle())
            try await rig.render(Self.middleFrames + 5000)

            #expect(rig.deviation(of: Self.a, from: Self.middleStart, at: 0, count: Self.middleFrames) == 0)
            #expect(isSilent(rig.out, in: Self.middleFrames..<rig.frame))
            #expect(rig.events == ["finished"])
            #expect(!rig.engine.isActive)
        }

        @Test("the last part of a file plays to the end of the file")
        func playsTheLastPart() async throws {
            let rig = EngineRig()
            let frames = Self.a.frames - Self.middleEnd
            rig.engine.start(try source(from: 2.4, to: nil))
            try await rig.render(frames + 5000)
            #expect(rig.deviation(of: Self.a, from: Self.middleEnd, at: 0, count: frames) == 0)
            #expect(isSilent(rig.out, in: frames..<rig.frame))
            #expect(rig.events == ["finished"])
        }

        @Test("the first part of a file starts with the first frame")
        func playsTheFirstPart() async throws {
            let rig = EngineRig()
            rig.engine.start(try source(from: 0, to: 1.0))
            try await rig.render(44_100 + 3000)
            #expect(rig.deviation(of: Self.a, from: 0, at: 0, count: 44_100) == 0)
            #expect(isSilent(rig.out, in: 44_100..<rig.frame))
        }

        @Test("position and length are the part's own, not the file's")
        func positionAndDuration() async throws {
            let rig = EngineRig()
            rig.engine.start(try middle())
            try await rig.render(10 * Self.slice)
            #expect(abs(rig.engine.position - Double(10 * Self.slice) / 44100) < 1e-6)
            let duration = try #require(rig.engine.duration)
            #expect(abs(duration - 1.4) < 1e-9)

            let file = try #require(rig.engine.currentFile)
            let expected = try middle()
            #expect(file.source == expected)
            #expect(abs(file.duration - 1.4) < 1e-9)
            #expect(file.codec.hasPrefix("FLAC"))
        }

        @Test("the length of an open-ended part is what is left of the file")
        func openEndedDuration() async throws {
            let rig = EngineRig()
            rig.engine.start(try source(from: 2.4, to: nil))
            try await rig.render(Self.slice)
            let duration = try #require(rig.engine.duration)
            #expect(abs(duration - Double(Self.a.frames - Self.middleEnd) / 44100) < 1e-9)
        }

        @Test("a part can be started inside itself; the offset counts from the part's start")
        func startInside() async throws {
            let rig = EngineRig()
            rig.engine.start(try middle(), at: 0.5)
            #expect(abs(rig.engine.position - 0.5) < 1e-9)
            let first = Self.middleStart + 22_050
            let frames = Self.middleFrames - 22_050
            try await rig.render(frames + 3000)
            #expect(rig.deviation(of: Self.a, from: first, at: 0, count: frames) == 0)
            #expect(isSilent(rig.out, in: frames..<rig.frame))
            #expect(rig.events == ["finished"])
        }

        @Test("tracks of one file follow each other without a gap or a lost sample: the file comes out whole",
              arguments: [[0.0, 1.0, 2.4], [0.0, 0.5, 1.0, 1.5, 2.0, 2.4, 3.0]])
        func gaplessInOneFile(cuts: [Double]) async throws {
            let rig = EngineRig()
            var parts = cuts.indices.map { i in PlaybackSource(url: (try? Self.a.url())!, start: cuts[i], end: i + 1 < cuts.count ? cuts[i + 1] : nil) }
            let first = parts.removeFirst()
            rig.react = { [engine = rig.engine] event in
                guard case .advanced = event, !parts.isEmpty else { return }
                engine.setNext(parts.removeFirst())
            }
            rig.engine.start(first, next: parts.removeFirst())
            try await rig.render(Self.a.frames + 3000)

            #expect(rig.deviation(of: Self.a, from: 0, at: 0, count: Self.a.frames) == 0)
            #expect(isSilent(rig.out, in: Self.a.frames..<rig.frame))
            #expect(rig.events == Array(repeating: "advanced", count: cuts.count - 1) + ["finished"])
        }

        @Test("a part and then a whole file, or the other way round, join gaplessly")
        func partThenFile() async throws {
            let rig = EngineRig()
            rig.engine.start(try middle(), next: PlaybackSource(url: try RampFile.b.url()))
            try await rig.render(Self.middleFrames + RampFile.b.frames + 3000)
            #expect(rig.deviation(of: Self.a, from: Self.middleStart, at: 0, count: Self.middleFrames) == 0)
            #expect(rig.deviation(of: .b, from: 0, at: Self.middleFrames, count: RampFile.b.frames) == 0)
            #expect(rig.events == ["advanced", "finished"])

            let other = EngineRig()
            other.engine.start(PlaybackSource(url: try RampFile.c.url()), next: try middle())
            try await other.render(RampFile.c.frames + Self.middleFrames + 3000)
            #expect(other.deviation(of: .c, from: 0, at: 0, count: RampFile.c.frames) == 0)
            #expect(other.deviation(of: Self.a, from: Self.middleStart, at: RampFile.c.frames, count: Self.middleFrames) == 0)
        }

        @Test("a part of a file at another rate is as long as it says, and joins the next track")
        func partOfAnotherRate() async throws {
            let rig = EngineRig()
            rig.engine.start(PlaybackSource(url: try RampFile.r48.url(), start: 0.5, end: 1.5), next: PlaybackSource(url: try RampFile.b.url()))
            try await rig.render(44_100 + RampFile.b.frames + 3000)
            // b starts exactly after 44 100 frames of the part.
            #expect(rig.deviation(of: .b, from: 0, at: 44_100, count: RampFile.b.frames) == 0)
            #expect(rig.events == ["advanced", "finished"])
        }

        @Test("seeking inside a part goes to the place of the part, not of the file",
              arguments: [0.0, 0.5, 1.0])
        func seekInside(seconds: Double) async throws {
            let rig = EngineRig()
            rig.engine.start(try middle())
            try await rig.render(4 * Self.slice)
            let at = rig.frame
            rig.engine.seek(to: seconds)
            #expect(rig.engine.position == seconds)
            try await rig.render(8 * Self.slice)

            let target = Self.middleStart + Int((seconds * 44100).rounded())
            let settled = at + rig.fadeFrames + rig.fadeInFrames
            let playable = min(rig.frame - settled, Self.middleEnd - target - rig.fadeInFrames)
            #expect(rig.deviation(of: Self.a, from: target + rig.fadeInFrames, at: settled, count: playable) == 0)
        }

        @Test("a seek past the end of the part goes to its last frame, and the track ends there")
        func seekPastTheEnd() async throws {
            let rig = EngineRig()
            rig.engine.start(try middle())
            try await rig.render(4 * Self.slice)
            rig.engine.seek(to: 10_000)
            #expect(abs(rig.engine.position - (1.4 - 1 / 44100)) < 1e-9)
            try await rig.render(6 * Self.slice)
            #expect(rig.events == ["finished"])
            #expect(!rig.engine.isActive)
        }

        @Test("a negative seek is the start of the part, not of the file")
        func seekNegative() async throws {
            let rig = EngineRig()
            rig.engine.start(try middle())
            try await rig.render(6 * Self.slice)
            let at = rig.frame
            rig.engine.seek(to: -5)
            try await rig.render(8 * Self.slice)
            let settled = at + rig.fadeFrames + rig.fadeInFrames
            #expect(rig.deviation(of: Self.a, from: Self.middleStart + rig.fadeInFrames, at: settled, count: rig.frame - settled) == 0)
        }

        @Test("the next track is told apart by its part: the same part again changes nothing, another part replaces it")
        func setNextParts() async throws {
            let rig = EngineRig()
            let next = try source(from: 2.4, to: nil)
            rig.engine.start(try middle(), next: next)
            try await rig.render(2 * Self.slice)
            let chunks = rig.engine.scheduledChunks
            rig.engine.setNext(next)
            #expect(rig.engine.scheduledChunks == chunks)
            #expect(rig.engine.isActive)

            // Same file, another part: it is the one that plays after the current track.
            rig.engine.setNext(try source(from: 0, to: 0.5))
            try await rig.render(Self.middleFrames + 30_000)
            #expect(rig.events == ["advanced", "finished"])
            let last = try #require((0..<rig.frame).last { rig.out[0][$0] != 0 || rig.out[1][$0] != 0 })
            #expect(rig.deviation(of: Self.a, from: 0, at: last + 1 - 22_050, count: 22_050) == 0)
        }

        @Test("a part that isn't in the file is a failure like a missing file, as the current track and as the next one")
        func partBeyondTheFile() async throws {
            let rig = EngineRig()
            rig.engine.start(try source(from: 10, to: 12))
            try await rig.render(4 * Self.slice)
            #expect(rig.events == ["failed:a.flac:current"])
            #expect(!rig.engine.isActive)

            let next = EngineRig()
            next.engine.start(try middle(), next: try source(from: 10, to: nil))
            try await next.render(Self.middleFrames + 4 * Self.slice)
            #expect(next.events.first == "failed:a.flac:next")
            #expect(next.events.last == "finished")
            #expect(next.deviation(of: Self.a, from: Self.middleStart, at: 0, count: Self.middleFrames) == 0)
        }

        // MARK: - Waveform

        @Test("the waveform key tells parts of a file apart, and is the old one for a whole file")
        func waveformKey() throws {
            let url = try Self.a.url()
            let whole = try #require(WaveformKey.make(url: url))
            #expect(WaveformKey.make(source: PlaybackSource(url: url)) == whole)
            #expect(WaveformKey.make(source: PlaybackSource(url: url, start: 0, end: nil)) == whole)

            let keys = [
                PlaybackSource(url: url, start: 1.0, end: 2.4), PlaybackSource(url: url, start: 1.0, end: 2.5),
                PlaybackSource(url: url, start: 1.1, end: 2.4), PlaybackSource(url: url, start: 1.0, end: nil),
                PlaybackSource(url: url, start: 0, end: 2.4),
            ].compactMap { WaveformKey.make(source: $0) }
            #expect(Set(keys + [whole]).count == 6)
            #expect(WaveformKey.make(source: PlaybackSource(url: url, start: 1.0, end: 2.4)) == keys[0])
            #expect(WaveformKey.make(source: PlaybackSource(url: URL(fileURLWithPath: "/nonexistent/a.flac"), start: 1)) == nil)
        }

        /// 16 bit stereo WAV with the given frames of a ramp file.
        private func wav(of file: RampFile, frames range: Range<Int>) -> Data {
            var pcm = Data(capacity: range.count * 4)
            for frame in range {
                for channel in 0..<2 {
                    let k = (frame * (7 + 6 * channel) + file.salt) % (1 << 16)
                    let value = Int16(k - 32768)
                    pcm.append(UInt8(truncatingIfNeeded: value))
                    pcm.append(UInt8(truncatingIfNeeded: value >> 8))
                }
            }
            var data = Data.ascii("RIFF")
            data.append(.le32(36 + pcm.count))
            data.append(.ascii("WAVEfmt "))
            data.append(.le32(16))
            data.append(Data([1, 0, 2, 0]))
            data.append(.le32(44100))
            data.append(.le32(44100 * 4))
            data.append(Data([4, 0, 16, 0]))
            data.append(.ascii("data"))
            data.append(.le32(pcm.count))
            data.append(pcm)
            return data
        }

        @Test("the waveform of a part is the waveform of those frames, whatever else is in the file")
        func waveformOfPart() throws {
            let dir = try TempDir()
            let cut = try dir.write("cut.wav", wav(of: Self.a, frames: Self.middleStart..<Self.middleEnd))
            let url = try Self.a.url()

            for workers in [1, 2, 3] {
                let part = try #require(WaveformAnalyzer.analyse(url: url, start: 1.0, end: 2.4, workers: workers) { false })
                let reference = try #require(WaveformAnalyzer.analyse(url: cut, workers: workers) { false })
                #expect(part == reference, "workers: \(workers)")
                #expect(part.isComplete)
            }

            // And an open end is the rest of the file.
            let tail = try dir.write("tail.wav", wav(of: Self.a, frames: Self.middleEnd..<Self.a.frames))
            let part = try #require(WaveformAnalyzer.analyse(url: url, start: 2.4, end: nil, workers: 2) { false })
            #expect(part == WaveformAnalyzer.analyse(url: tail, workers: 2) { false })
        }

        @Test("the waveform of a part doesn't depend on how many workers read it")
        func waveformWorkers() throws {
            let url = try Self.a.url()
            let one = try #require(WaveformAnalyzer.analyse(url: url, start: 1.0, end: 2.4, workers: 1) { false })
            let two = try #require(WaveformAnalyzer.analyse(url: url, start: 1.0, end: 2.4, workers: 2) { false })
            #expect(one == two)
            #expect(one.waveform.rms.count > 1000 && one.waveform.rms.count <= Waveform.bucketCount)
        }

        @Test("the whole file as an explicit part is the whole file")
        func waveformWholeAsPart() throws {
            let url = try Self.a.url()
            let whole = WaveformAnalyzer.analyse(url: url, workers: 2) { false }
            #expect(whole != nil)
            #expect(WaveformAnalyzer.analyse(url: url, start: 0, end: Self.a.duration, workers: 2) { false } == whole)
            #expect(WaveformAnalyzer.analyse(url: url, start: 0, end: 99, workers: 2) { false } == whole)
        }

        @Test("a part that isn't in the file has no waveform")
        func waveformBeyond() throws {
            let url = try Self.a.url()
            #expect(WaveformAnalyzer.analyse(url: url, start: 10, end: 12, workers: 2) { false } == nil)
            #expect(WaveformAnalyzer.analyse(url: url, start: 3.5, end: nil, workers: 2) { false } == nil)
            #expect(WaveformAnalyzer.analyse(url: url, start: 1, end: 1, workers: 2) { false } == nil)
            #expect(WaveformAnalyzer.analyse(url: url, start: 2, end: 1, workers: 2) { false } == nil)
        }

        @Test("a very short part still has a waveform")
        func waveformShortPart() throws {
            let url = try Self.a.url()
            let part = WaveformAnalyzer.analyse(url: url, start: 1.0, end: 1.0 + 100.0 / 44100, workers: 2) { false }
            #expect(part?.waveform.rms.count == 100)
        }

        // MARK: - Playback of a playlist

        @MainActor private struct Env {
            let dir: TempDir
            let store: PlaylistStore
            let rig: EngineRig
            let state: PlaybackState

            func run(_ frames: Int) async throws {
                try await rig.render(frames)
                state.tick()
            }
        }

        private final class Recorder: PlaybackListener {
            var started: [PlayedTrack] = []
            var ended: [(PlayedTrack, TimeInterval)] = []
            func trackDidStart(_ track: PlayedTrack) { started.append(track) }
            func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval) { ended.append((track, playedSeconds)) }
        }

        private func cueEntry(_ number: Int, start: Double, end: Double?, title: String, duration: Double? = nil,
                              file: RampFile = .a) throws -> TrackEntry {
            let url = try file.url()
            let sheet = url.deletingLastPathComponent().appendingPathComponent("sheet.cue").path
            return TrackEntry(path: CuePath.make(sheet: sheet, number: number), artist: "Artist", album: "Sheet", title: title,
                              trackNumber: number, year: nil, duration: duration ?? end.map { $0 - start }, codec: "FLAC",
                              cue: CueSlice(sheet: sheet, number: number, file: url.path, start: start, end: end))
        }

        /// The sheet: One = 0 ..< 1.0, Two = 1.0 ..< 2.4, Three = 2.4 ..< end of file.
        private func sheet(three: Double? = nil) throws -> [TrackEntry] {
            [try cueEntry(1, start: 0, end: 1.0, title: "One"),
             try cueEntry(2, start: 1.0, end: 2.4, title: "Two"),
             try cueEntry(3, start: 2.4, end: nil, title: "Three", duration: three)]
        }

        private func makeEnv(_ entries: [TrackEntry], listener: PlaybackListener? = nil) async throws -> Env {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            let store = PlaylistStore(paths: paths, configStore: config)
            #expect(await waitUntil { !store.isLoading })
            await store.append(Make.albums(entries), to: "main")
            let rig = EngineRig()
            let state = PlaybackState(store: store, engine: rig.engine, tickInterval: nil, positionStep: 0,
                                      listeners: listener.map { [$0] } ?? [])
            state.volume = 1
            let existing = rig.engine.onEvent
            rig.engine.onEvent = { [weak rig] event in
                rig?.record(event)
                existing?(event)
            }
            return Env(dir: dir, store: store, rig: rig, state: state)
        }

        @Test("starting a track of a sheet plays its part and shows it")
        func stateStart() async throws {
            let env = try await makeEnv(try sheet())
            env.state.play(albumIndex: 0, trackIndex: 1)
            #expect(env.state.info?.title == "Two")
            #expect(env.state.info?.album == "Sheet")
            #expect(env.state.info?.codec == "FLAC")

            try await env.run(6 * Self.slice)
            #expect(env.rig.deviation(of: Self.a, from: Self.middleStart, at: 0, count: 6 * Self.slice) == 0)
            #expect(abs(env.state.duration - 1.4) < 1e-9)
            #expect(abs(env.state.position - Double(6 * Self.slice) / 44100) < 1e-6)
        }

        @Test("the sheet plays through track after track, gaplessly, the title following along")
        func statePlaysThrough() async throws {
            let env = try await makeEnv(try sheet())
            env.state.play(albumIndex: 0, trackIndex: 0)
            try await env.run(50_000)
            #expect(env.state.info?.title == "Two")
            #expect(abs(env.state.position - Double(50_000 - 44_100) / 44100) < 1e-3)

            try await env.run(60_000)
            #expect(env.state.info?.title == "Three")

            try await env.run(Self.a.frames - 110_000 + 3000)
            #expect(env.rig.deviation(of: Self.a, from: 0, at: 0, count: Self.a.frames) == 0)
            #expect(env.rig.events == ["advanced", "advanced", "finished"])
            #expect(env.state.status == .stopped)
        }

        @Test("next and previous move between the tracks of a sheet")
        func stateNextPrevious() async throws {
            let env = try await makeEnv(try sheet())
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.nextTrack()
            #expect(env.state.info?.title == "Two")
            try await env.run(8 * Self.slice)
            #expect(env.rig.deviation(of: Self.a, from: Self.middleStart, at: 0, count: 8 * Self.slice) == 0)

            env.state.nextTrack()
            #expect(env.state.info?.title == "Three")
            env.state.previousTrack()
            #expect(env.state.info?.title == "Two")
            env.state.previousTrack()
            #expect(env.state.info?.title == "One")
        }

        @Test("seeking is inside the track that plays")
        func stateSeek() async throws {
            let env = try await makeEnv(try sheet())
            env.state.play(albumIndex: 0, trackIndex: 1)
            try await env.run(2 * Self.slice)
            env.state.seek(to: 1.0)
            try await env.run(8 * Self.slice)

            let settled = 2 * Self.slice + env.rig.fadeFrames + env.rig.fadeInFrames
            let target = Self.middleStart + 44_100
            #expect(env.rig.deviation(of: Self.a, from: target + env.rig.fadeInFrames, at: settled, count: 4 * Self.slice) == 0)
            #expect(env.state.info?.title == "Two")
            #expect(env.state.position > 1.0 && env.state.position < 1.4)
        }

        @Test("what playback measures of a track corrects the playlist, for the part and not the file")
        func stateCorrectsDurations() async throws {
            let entries = [try cueEntry(1, start: 0, end: 1.0, title: "One", duration: 77),
                           try cueEntry(2, start: 1.0, end: 2.4, title: "Two"),
                           try cueEntry(3, start: 2.4, end: nil, title: "Three", duration: 10)]
            let env = try await makeEnv(entries)
            let playlist = try #require(env.store.playlist(named: "main"))
            let ids = playlist.entries.map(\.id)

            for index in 0..<3 {
                env.state.play(albumIndex: 0, trackIndex: index)
                try await env.run(2 * Self.slice)
            }
            let corrected = try #require(env.store.playlist(named: "main"))
            let durations = ids.map { corrected.track(id: $0)?.duration ?? -1 }
            #expect(abs(durations[0] - 1.0) < 1e-9)                                      // was 77
            #expect(abs(durations[1] - 1.4) < 1e-9)                                      // was right, kept
            #expect(abs(durations[2] - Double(Self.a.frames - Self.middleEnd) / 44100) < 1e-9)   // was 10
            #expect(corrected.entries.map(\.cue) == playlist.entries.map(\.cue))
            #expect(corrected.entries.map(\.path) == playlist.entries.map(\.path))
        }

        @Test("a track whose part isn't in the file is skipped like a missing file")
        func stateSkipsBrokenPart() async throws {
            let entries = [try cueEntry(1, start: 0, end: 1.0, title: "One"),
                           try cueEntry(2, start: 10, end: 11, title: "Beyond"),
                           try cueEntry(3, start: 2.4, end: nil, title: "Three")]
            let env = try await makeEnv(entries)
            env.state.play(albumIndex: 0, trackIndex: 0)
            let three = Self.a.frames - Self.middleEnd
            try await env.run(44_100 + three + 3000)

            #expect(env.rig.deviation(of: Self.a, from: 0, at: 0, count: 44_100) == 0)
            #expect(env.rig.deviation(of: Self.a, from: Self.middleEnd, at: 44_100, count: three) == 0)
            #expect(env.rig.events.contains("failed:a.flac:next"))
            #expect(env.state.status == .stopped)
        }

        @Test("tracks of one sheet can be played in any order, also from different places in the playlist")
        func stateReordered() async throws {
            let entries = try sheet()
            let env = try await makeEnv([entries[2], entries[0], entries[1]])
            env.state.play(albumIndex: 0, trackIndex: 0)        // "Three" is first now
            #expect(env.state.info?.title == "Three")
            try await env.run(3 * Self.slice)
            #expect(env.rig.deviation(of: Self.a, from: Self.middleEnd, at: 0, count: 3 * Self.slice) == 0)
            env.state.nextTrack()
            #expect(env.state.info?.title == "One")
            try await env.run(8 * Self.slice)
            #expect(env.rig.deviation(of: Self.a, from: env.rig.fadeInFrames, at: 3 * Self.slice + env.rig.fadeFrames + env.rig.fadeInFrames,
                                      count: 4 * Self.slice) == 0)
        }

        @Test("listeners hear which part plays")
        func stateListeners() async throws {
            let recorder = Recorder()
            let env = try await makeEnv(try sheet(), listener: recorder)
            env.state.play(albumIndex: 0, trackIndex: 1)
            try await env.run(Self.slice)

            let played = try #require(recorder.started.first)
            #expect(played.title == "Two" && played.album == "Sheet")
            #expect(played.cue?.number == 2)
            let expected = try middle()
            let url = try Self.a.url()
            #expect(played.source == expected)
            #expect(played.url == url)
            #expect(abs(played.duration - 1.4) < 1e-9)
            #expect(played.hasTags)
        }

        @Test("the end of the last track of a sheet is the end of the playlist")
        func stateEnd() async throws {
            let env = try await makeEnv(try sheet())
            env.state.play(albumIndex: 0, trackIndex: 2)
            try await env.run(Self.a.frames - Self.middleEnd + 3000)
            #expect(env.rig.events == ["finished"])
            #expect(env.state.status == .stopped)
        }

        @Test("with the queue, a track of a sheet plays after the current one, whatever comes after it in the sheet")
        func stateQueue() async throws {
            let env = try await makeEnv(try sheet())
            let list = try #require(env.store.playlist(named: "main"))
            env.state.play(albumIndex: 0, trackIndex: 0)
            env.state.enqueue([QueueEntry(playlist: "main", id: list.entries[2].id)])
            env.state.nextTrack()
            #expect(env.state.info?.title == "Three")
            try await env.run(3 * Self.slice)
            #expect(env.rig.deviation(of: Self.a, from: Self.middleEnd, at: 0, count: 3 * Self.slice) == 0)
        }
    }
}
