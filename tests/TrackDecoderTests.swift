import AVFoundation
import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("TrackDecoder")
    struct TrackDecoderTests {
        private struct Decoded {
            var samples: [[Float]] = [[], []]
            var warning: String?
            var failure: String?
            var chunks = 0
            var fileDuration: Double?
            var formats: [AVAudioFormat] = []
        }

        private func outputFormat(_ rate: Double) -> AVAudioFormat {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        }

        private func decode(_ url: URL, from start: Double = 0, rate: Double = 44100, maxChunks: Int = .max,
                            quality: ResampleQuality = .default) async -> Decoded {
            let decoder = TrackDecoder(url: url, startSeconds: start, outputFormat: outputFormat(rate),
                                       resampleQuality: quality)
            var result = Decoded()
            while result.chunks < maxChunks {
                switch await decoder.next() {
                case .chunk(let chunk):
                    result.chunks += 1
                    result.fileDuration = chunk.fileDuration
                    result.formats.append(chunk.buffer.format)
                    for channel in 0..<2 {
                        result.samples[channel].append(contentsOf: UnsafeBufferPointer(
                            start: chunk.buffer.floatChannelData![channel], count: Int(chunk.buffer.frameLength)))
                    }
                case .finished(let warning):
                    result.warning = warning
                    return result
                case .failed(let message):
                    result.failure = message
                    return result
                }
            }
            return result
        }

        // MARK: Exactness

        @Test("lossless files are delivered sample by sample, with exactly the announced length",
              arguments: [RampFile.a, .b, .c, .tiny, .tiny2, .a.stored(as: "a.wav"), .a.stored(as: "a.aiff"),
                          .a.stored(as: "a.caf"), .a.stored(as: "a_alac.m4a")])
        func exact(file: RampFile) async throws {
            let d = await decode(try file.url())
            #expect(d.failure == nil && d.warning == nil)
            #expect(d.samples.frameCount == file.frames)
            #expect(maxDeviation(d.samples, from: 0, count: file.frames) { file.value($0, channel: $1) } == 0)
            #expect(d.fileDuration == file.duration)
        }

        @Test("24 bit audio at 96 kHz comes out exactly when the output has the same rate")
        func hiRes() async throws {
            let d = await decode(try RampFile.r96.url(), rate: 96000)
            #expect(d.samples.frameCount == RampFile.r96.frames)
            #expect(maxDeviation(d.samples, from: 0, count: RampFile.r96.frames) { RampFile.r96.value($0, channel: $1) } == 0)
        }

        @Test("a FLAC ends at its last real frame, without the padding AVFoundation's player adds")
        func noPadding() async throws {
            // 136710 is not a multiple of the 4096 sample FLAC block size.
            #expect(RampFile.a.frames % 4096 != 0)
            let d = await decode(try RampFile.a.url())
            #expect(d.samples.frameCount == 136_710)
        }

        @Test("chunks are in the engine's format and no bigger than a few blocks")
        func chunkFormat() async throws {
            let d = await decode(try RampFile.a.url())
            #expect(d.chunks == Int((Double(RampFile.a.frames) / Double(TrackDecoder.blockFrames)).rounded(.up)))
            for f in d.formats {
                #expect(f == outputFormat(44100))
                #expect(f.channelCount == 2 && f.commonFormat == .pcmFormatFloat32 && !f.isInterleaved)
            }
        }

        @Test("asking again after the end keeps saying it's over")
        func afterEnd() async throws {
            let decoder = TrackDecoder(url: try RampFile.tiny.url(), startSeconds: 0, outputFormat: outputFormat(44100))
            var chunks = 0
            while case .chunk = await decoder.next() { chunks += 1 }
            #expect(chunks == 1)
            for _ in 0..<3 {
                guard case .finished(let warning) = await decoder.next() else { Issue.record("expected finished"); return }
                #expect(warning == nil)
            }
        }

        // MARK: Starting in the middle

        @Test("starting at an offset delivers the audio from exactly that frame",
              arguments: [0.0, 0.5, 1.0, 1.2345, 2.9, 3.09])
        func startOffset(seconds: Double) async throws {
            let file = RampFile.a
            let first = Int((seconds * file.sampleRate).rounded())
            let d = await decode(try file.url(), from: seconds)
            #expect(d.failure == nil)
            #expect(d.samples.frameCount == file.frames - first)
            #expect(maxDeviation(d.samples, from: 0, count: d.samples.frameCount) { file.value(first + $0, channel: $1) } == 0)
        }

        @Test("every container seeks to the right frame", arguments: ["a.wav", "a.aiff", "a.caf", "a_alac.m4a"])
        func seekContainers(name: String) async throws {
            let file = RampFile.a.stored(as: name)
            let first = 70_001
            let d = await decode(try file.url(), from: Double(first) / file.sampleRate)
            #expect(d.samples.frameCount == file.frames - first)
            #expect(maxDeviation(d.samples, from: 0, count: d.samples.frameCount) { file.value(first + $0, channel: $1) } == 0)
        }

        @Test("a start past the end plays the last frame instead of failing")
        func startPastEnd() async throws {
            let file = RampFile.a
            let d = await decode(try file.url(), from: 10_000)
            #expect(d.failure == nil)
            #expect(d.samples.frameCount == 1)
            #expect(d.samples[0][0] == file.value(file.frames - 1, channel: 0))
        }

        @Test("a negative start is treated as the beginning")
        func negativeStart() async throws {
            let d = await decode(try RampFile.tiny.url(), from: -5)
            #expect(d.samples.frameCount == RampFile.tiny.frames)
        }

        // MARK: Channels

        @Test("mono is delivered on both channels at full level")
        func mono() async throws {
            let file = RampFile.mono22
            let d = await decode(try file.url(), rate: file.sampleRate)
            #expect(d.samples.frameCount == file.frames)
            #expect(maxDeviation(d.samples, from: 0, count: file.frames) { file.stereo($0, channel: $1) } == 0)
        }

        @Test("5.1 is folded down without clipping")
        func surround() async throws {
            let file = RampFile.surround
            let d = await decode(try file.url())
            #expect(d.samples.frameCount == file.frames)
            #expect(peak(d.samples, in: 0..<file.frames) <= 1.0001)
            // The front channels are in there (the ramp is loud, so the mix isn't silence either).
            #expect(peak(d.samples, in: 0..<file.frames) > 0.3)
        }

        // MARK: Resampling

        /// Frames at each end of a resampled file where the converter's filter has no signal on one side, so the
        /// result is only roughly right (at most about 3% of the 0.5 amplitude used here, over about a millisecond).
        private static let edgeFrames = 64

        private func tone(_ file: ToneFile, outputRate: Double) async throws {
            let d = await decode(try file.url(), rate: outputRate)
            #expect(d.failure == nil && d.warning == nil)
            let expectedFrames = Int((Double(file.frames) * outputRate / file.sampleRate).rounded())
            #expect(d.samples.frameCount == expectedFrames, "\(file.name) -> \(outputRate): frame count")

            let channels = file.channels
            let expected = { (i: Int, c: Int) in ToneFile.value(at: Double(i) / outputRate, channel: channels == 1 ? 0 : c) }
            let edge = Self.edgeFrames
            let interior = maxDeviation(d.samples, from: edge, count: d.samples.frameCount - 2 * edge) { expected($0 + edge, $1) }
            let head = maxDeviation(d.samples, from: 0, count: edge, expected: expected)
            let tail = maxDeviation(d.samples, from: d.samples.frameCount - edge, count: edge) {
                expected($0 + d.samples.frameCount - edge, $1)
            }
            #expect(interior < 0.0005, "\(file.name) -> \(outputRate): interior deviation \(interior)")
            #expect(head < 0.03 && tail < 0.03, "\(file.name) -> \(outputRate): edges \(head) \(tail)")
        }

        @Test("44.1 kHz audio at other rates follows the original waveform, with exactly the right length",
              arguments: [48000.0, 96000, 88200, 32000, 22050, 192000])
        func resampleFrom44(rate: Double) async throws {
            try await tone(.sine44, outputRate: rate)
        }

        @Test("every resample quality gives the exact length and follows the waveform, and the setting is used",
              arguments: ResampleQuality.allCases)
        func resampleQualities(quality: ResampleQuality) async throws {
            let file = ToneFile.sine48
            let url = try file.url()
            let d = await decode(url, rate: 44100, quality: quality)
            #expect(d.failure == nil)
            #expect(d.samples.frameCount == Int((Double(file.frames) * 44100 / 48000).rounded()))
            let skip = 400
            let deviation = maxDeviation(d.samples, from: skip, count: d.samples.frameCount - 2 * skip) { i, c in
                ToneFile.value(at: Double(i + skip) / 44100, channel: c)
            }
            #expect(deviation < 0.05, "\(quality): \(deviation)")

            // The converter really is set up differently (the quality isn't ignored).
            if quality != .default {
                let reference = await decode(url, rate: 44100)
                #expect(reference.samples != d.samples)
            }
        }

        @Test("48, 32 and 96 kHz audio is brought to 44.1 kHz")
        func resampleTo44() async throws {
            try await tone(.sine48, outputRate: 44100)
            try await tone(.sine32, outputRate: 44100)
            try await tone(.sine96, outputRate: 44100)
        }

        @Test("resampling a mono file works too")
        func resampleMono() async throws {
            try await tone(.sine22mono, outputRate: 48000)
        }

        @Test("resampling from the middle of a file starts at the right place")
        func resampleOffset() async throws {
            let file = ToneFile.sine48
            let d = await decode(try file.url(), from: 1.0, rate: 44100)
            let expected = Int((Double(file.frames - 48_000) * 44100 / 48000).rounded())
            #expect(d.samples.frameCount == expected)
            // After the converter's start-up, the waveform continues at 1.0 s.
            let skip = 200
            let deviation = maxDeviation(d.samples, from: skip, count: d.samples.frameCount - skip) { i, c in
                ToneFile.value(at: 1.0 + Double(i + skip) / 44100, channel: c)
            }
            #expect(deviation < 0.01, "deviation \(deviation)")
        }

        @Test("a resampled file doesn't depend on how it is chunked: its first and last frames are in place")
        func resampleEdges() async throws {
            let d = await decode(try ToneFile.sine48.url(), rate: 44100)
            #expect(abs(d.samples[0][0]) < 0.01)                         // sine starts at 0
            // The tail doesn't fade out or get cut: the last samples still follow the sine.
            let last = d.samples.frameCount - 1
            #expect(abs(d.samples[0][last] - ToneFile.value(at: Double(last) / 44100, channel: 0)) < 0.01)
        }

        @Test("resampling doesn't introduce steps (clicks) in the signal")
        func resampleSmooth() async throws {
            let d = await decode(try ToneFile.sine48.url(), rate: 44100)
            #expect(maxStep(d.samples, in: 0..<d.samples.frameCount) <= ToneFile.maxStep(rate: 44100) * 1.05)
        }

        // MARK: Compressed formats

        @Test("MP3, AAC and Vorbis are decoded in full", arguments: ["lossy.mp3", "lossy.m4a", "lossy.ogg"])
        func lossy(name: String) async throws {
            let d = await decode(try Fixtures.url("playback/" + name))
            #expect(d.failure == nil)
            let seconds = Double(d.samples.frameCount) / 44100
            #expect(abs(seconds - 3) < 0.12, "\(name): \(seconds) s")
            #expect(abs(d.fileDuration! - 3) < 0.12)
            // ffmpeg's `sine` source is quiet (amplitude around 1/8): audible content, not silence.
            #expect(peak(d.samples, in: 0..<d.samples.frameCount) > 0.05)
        }

        @Test("seeking in compressed formats lands where it should", arguments: ["lossy.mp3", "lossy.m4a", "lossy.ogg"])
        func lossySeek(name: String) async throws {
            let url = try Fixtures.url("playback/" + name)
            let whole = await decode(url)
            let half = await decode(url, from: 1.5)
            let expected = whole.samples.frameCount - Int(1.5 * 44100)
            // Encoder delay and block sizes allow a little slack; being off by whole blocks or seconds doesn't.
            #expect(abs(half.samples.frameCount - expected) < 2500, "\(name): \(half.samples.frameCount) vs \(expected)")
        }

        // MARK: Errors

        @Test("a missing file fails")
        func missing() async {
            let d = await decode(URL(fileURLWithPath: "/nonexistent/x.flac"))
            #expect(d.failure != nil)
            #expect(d.samples.frameCount == 0)
        }

        @Test("garbage and an empty file fail", arguments: ["garbage.mp3", "empty.flac"])
        func broken(name: String) async throws {
            let d = await decode(try Fixtures.url("broken/" + name))
            #expect(d.failure != nil, "\(name)")
            #expect(d.samples.frameCount == 0)
        }

        @Test("a video pretending to be an mp3 yields at most a blip of noise, never real playback")
        func disguisedVideo() async throws {
            // AVAudioFile opens it and decodes a few frames of junk. Such files don't get into a playlist (the
            // tag reader rejects them); this only pins down that the decoder doesn't hang or play on.
            let d = await decode(try Fixtures.url("broken/video.mp3"))
            #expect(d.samples.frameCount < 4410)   // under a tenth of a second
        }

        @Test("a file cut short ends where the data ends, with a warning")
        func truncated() async throws {
            let d = await decode(try Fixtures.url("playback/truncated.flac"))
            #expect(d.failure == nil)
            #expect(d.samples.frameCount > 0 && d.samples.frameCount < RampFile.a.frames)
            #expect(d.warning != nil)
            // What was delivered is right.
            #expect(maxDeviation(d.samples, from: 0, count: d.samples.frameCount) { RampFile.a.value($0, channel: $1) } == 0)
        }

        @Test("a cancelled decoder delivers nothing more")
        func cancelled() async throws {
            let decoder = TrackDecoder(url: try RampFile.a.url(), startSeconds: 0, outputFormat: outputFormat(44100))
            guard case .chunk = await decoder.next() else { Issue.record("expected a chunk"); return }
            decoder.cancel()
            guard case .finished = await decoder.next() else { Issue.record("expected finished"); return }
        }

        @Test("decoders on different queues don't wait for each other")
        func independent() async throws {
            let a = TrackDecoder(url: try RampFile.a.url(), startSeconds: 0, outputFormat: outputFormat(44100))
            let b = TrackDecoder(url: try RampFile.b.url(), startSeconds: 0, outputFormat: outputFormat(44100))
            async let x = a.next()
            async let y = b.next()
            let (rx, ry) = await (x, y)
            guard case .chunk = rx, case .chunk = ry else { Issue.record("expected two chunks"); return }
        }
    }
}
