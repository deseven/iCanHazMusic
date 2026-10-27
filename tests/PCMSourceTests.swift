// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// What the sources that `TrackDecoder` and `WaveformAnalyzer` read files through say about a file and deliver, for
    /// WavPack and APE (which macOS can't open, the app decodes them with the libraries of `vendor/`) next to what
    /// `AVAudioFile` reads.
    @MainActor @Suite("PCM sources")
    struct PCMSourceTests {
        /// Everything a source delivered, per channel.
        private struct Delivered {
            var samples: [[Float]]
            var failure: String?
            var frames: Int { samples.first?.count ?? 0 }
        }

        private func open(_ name: String) throws -> PCMSource {
            try PCMSources.open(url: Fixtures.url("playback/" + name))
        }

        private func readAll(_ source: PCMSource, block: Int = 4096) -> Delivered {
            let channels = Int(source.processingFormat.channelCount)
            var result = Delivered(samples: Array(repeating: [], count: channels))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(block)),
                  let data = buffer.floatChannelData else {
                result.failure = "no buffer"
                return result
            }
            while true {
                do {
                    try source.read(into: buffer, frameCount: AVAudioFrameCount(block))
                } catch {
                    result.failure = error.localizedDescription
                    break
                }
                guard buffer.frameLength > 0 else { break }
                for channel in 0..<channels {
                    result.samples[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
                }
            }
            return result
        }

        /// The largest difference between what was delivered (from frame `first` of the file) and the ramp.
        private func deviation(_ delivered: Delivered, from first: Int = 0, of file: RampFile) -> Float {
            var worst: Float = 0
            for (channel, samples) in delivered.samples.enumerated() {
                for (i, sample) in samples.enumerated() {
                    worst = max(worst, abs(sample - file.value(first + i, channel: channel)))
                }
            }
            return worst
        }

        // MARK: What a source is

        @Test("the source is picked by the extension, in any case")
        func picked() throws {
            #expect(try open("a.flac") is AVAudioFileSource)
            #expect(try open("a.wv") is WavPackSource)
            #expect(try open("a.ape") is APESource)
            let dir = try TempDir()
            #expect(try PCMSources.open(url: dir.copy("playback/a.wv", to: "A.WV")) is WavPackSource)
            #expect(try PCMSources.open(url: dir.copy("playback/a.ape", to: "A.Ape")) is APESource)
        }

        @Test("a file that isn't what its extension says is refused", arguments: [
            ("broken/garbage.wv", "wv"), ("broken/garbage.ape", "ape"), ("formats/t.flac", "wv"), ("formats/t.flac", "ape"),
            ("playback/a.ape", "wv"), ("playback/a.wv", "ape"),
        ])
        func refused(fixture: String, ext: String) throws {
            let url = try TempDir().copy(fixture, to: "x." + ext)
            #expect(throws: (any Error).self) { try PCMSources.open(url: url) }
        }

        @Test("a missing, an empty and a folder-shaped file are refused", arguments: ["wv", "ape"])
        func unreadable(ext: String) throws {
            let dir = try TempDir()
            #expect(throws: (any Error).self) { try PCMSources.open(url: dir.path("nope." + ext)) }
            let empty = try dir.write("empty." + ext)
            #expect(throws: (any Error).self) { try PCMSources.open(url: empty) }
            let folder = try dir.mkdir("folder." + ext)
            #expect(throws: (any Error).self) { try PCMSources.open(url: folder) }
        }

        @Test("length, rate and channels are the file's", arguments: [
            ("a.wv", 136_710, 44100.0, 2), ("a.ape", 136_710, 44100.0, 2),
            ("r96_24.wv", 192_000, 96000.0, 2), ("r96_24.ape", 192_000, 96000.0, 2),
            ("mono22.wv", 33_075, 22050.0, 1), ("mono22.ape", 33_075, 22050.0, 1),
            ("surround.wv", 66_150, 44100.0, 6), ("surround.ape", 66_150, 44100.0, 6),
            ("float.wv", 136_710, 44100.0, 2), ("hybrid.wv", 136_710, 44100.0, 2),
        ])
        func facts(name: String, frames: Int, rate: Double, channels: Int) throws {
            let source = try open(name)
            #expect(source.length == Int64(frames))
            #expect(source.processingFormat.sampleRate == rate)
            #expect(Int(source.processingFormat.channelCount) == channels)
            #expect(source.processingFormat.commonFormat == .pcmFormatFloat32 && !source.processingFormat.isInterleaved)
            #expect(source.framePosition == 0)
        }

        // MARK: Samples

        @Test("every kind of file is delivered sample by sample",
              arguments: [RampFile.a.stored(as: "a.wv"), .a.stored(as: "a.ape"),
                          .r96.stored(as: "r96_24.wv"), .r96.stored(as: "r96_24.ape"),
                          .mono22.stored(as: "mono22.wv"), .mono22.stored(as: "mono22.ape"),
                          .surround.stored(as: "surround.wv"), .surround.stored(as: "surround.ape"),
                          .float, .a.stored(as: "hybrid.wv")])
        func exact(file: RampFile) throws {
            let source = try open(file.name)
            let delivered = readAll(source)
            #expect(delivered.failure == nil, "\(delivered.failure ?? "")")
            #expect(delivered.frames == file.frames)
            #expect(deviation(delivered, of: file) == 0)
            #expect(source.framePosition == source.length)
        }

        @Test("reads of any size give the same samples", arguments: ["a.wv", "a.ape"])
        func blockSizes(name: String) throws {
            let file = RampFile.a.stored(as: name)
            for block in [3, 1000, 4097, 20_000] {
                let delivered = readAll(try open(name), block: block)
                #expect(delivered.frames == file.frames, "\(block)")
                #expect(deviation(delivered, of: file) == 0, "\(block)")
            }
        }

        @Test("a read asks for at most the room the buffer has", arguments: ["a.wv", "a.ape"])
        func capacity(name: String) throws {
            let source = try open(name)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 100))
            try source.read(into: buffer, frameCount: 5000)
            #expect(buffer.frameLength == 100)
            #expect(source.framePosition == 100)
        }

        // MARK: Seeking

        @Test("a seek lands on the exact frame, forwards and backwards", arguments: ["a.wv", "a.ape", "a.flac"])
        func seek(name: String) throws {
            let file = RampFile.a.stored(as: name)
            let source = try open(name)
            for first in [1, 4097, 70_001, file.frames - 10, file.frames - 1, 0, 100_000, 5] {
                try source.seek(to: Int64(first))
                #expect(source.framePosition == Int64(first))
                let delivered = readAll(source)
                #expect(delivered.failure == nil, "\(first)")
                #expect(delivered.frames == file.frames - first, "\(first)")
                #expect(deviation(delivered, from: first, of: file) == 0, "\(first)")
            }
        }

        @Test("a seek outside the file is refused and changes nothing", arguments: ["a.wv", "a.ape", "a.flac"])
        func seekOutside(name: String) throws {
            let file = RampFile.a.stored(as: name)
            let source = try open(name)
            try source.seek(to: 1000)
            for frame in [-1, file.frames, file.frames + 5, Int.max] {
                #expect(throws: (any Error).self, "\(frame)") { try source.seek(to: Int64(frame)) }
            }
            let delivered = readAll(source)
            #expect(delivered.frames == file.frames - 1000)
            #expect(deviation(delivered, from: 1000, of: file) == 0)
        }

        @Test("at the end there is nothing more, however often it is asked", arguments: ["a.wv", "a.ape", "a.flac"])
        func end(name: String) throws {
            let source = try open(name)
            try source.seek(to: source.length - 10)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096))
            try source.read(into: buffer, frameCount: 4096)
            #expect(buffer.frameLength == 10)
            for _ in 0..<3 {
                try source.read(into: buffer, frameCount: 4096)
                #expect(buffer.frameLength == 0)
            }
        }

        // MARK: Formats

        @Test("a hybrid WavPack file is lossless with its correction file")
        func hybridLossless() throws {
            let source = try open("hybrid.wv")
            #expect(source.codec == "WV 16/44.1")
            #expect(deviation(readAll(source), of: .a) == 0)
        }

        @Test("a hybrid WavPack file without its correction file is the lossy audio it holds")
        func hybridLossy() throws {
            let dir = try TempDir()
            let source = try PCMSources.open(url: dir.copy("playback/hybrid.wv", to: "hybrid.wv"))
            #expect(source.length == Int64(RampFile.a.frames))
            let label = source.codec
            #expect(label.hasPrefix("WV ") && label.hasSuffix("k"), "\(label)")
            #expect(Int(label.dropFirst(3).dropLast()).map { (100...400).contains($0) } == true, "\(label)")

            let delivered = readAll(source)
            #expect(delivered.failure == nil && delivered.frames == RampFile.a.frames)
            let worst = deviation(delivered, of: .a)
            // Not the ramp, but it, a little off.
            #expect(worst > 0 && worst < 0.1, "\(worst)")
        }

        @Test("DSD is decoded to PCM")
        func dsd() throws {
            let source = try open("dsd.wv")
            #expect(source.codec == "WV DSD64")
            #expect(source.processingFormat.sampleRate == 352_800 && source.processingFormat.channelCount == 2)
            // 8 blocks of 4096 bytes: a frame is a byte of the one bit stream.
            #expect(source.length == 32_768)
            let delivered = readAll(source)
            #expect(delivered.failure == nil && delivered.frames == 32_768)
            // The pattern is DSD's silence.
            #expect(delivered.samples.flatMap { $0 }.allSatisfy { abs($0) < 0.01 })

            try source.seek(to: 20_000)
            #expect(readAll(source).frames == 32_768 - 20_000)
        }

        @Test("the channels of a multichannel file come with their layout", arguments: ["surround.wv", "surround.ape"])
        func layout(name: String) throws {
            let source = try open(name)
            let labels = try #require(ChannelDownmix.labels(of: source.processingFormat))
            #expect(Array(labels.prefix(4)) == [kAudioChannelLabel_Left, kAudioChannelLabel_Right,
                                                kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen])
            // 5.1 is mixed as it is for a FLAC: the centre at -3 dB on both sides, the LFE dropped, the rest to its side.
            let expected = ChannelDownmix(channelCount: 6, labels: [
                kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
            ])
            #expect(ChannelDownmix(format: source.processingFormat) == expected)
        }

        // MARK: Damaged files

        @Test("a truncated file gives what is there, and ends there", arguments: ["truncated.wv", "truncated.ape"])
        func truncated(name: String) throws {
            let source = try open(name)
            let delivered = readAll(source)
            #expect(delivered.frames > 0 && delivered.frames < RampFile.a.frames)
            #expect(deviation(delivered, of: .a) == 0)
        }

        @Test("a damaged block is an error, after the audio in front of it", arguments: ["damaged.wv", "damaged.ape"])
        func damaged(name: String) throws {
            let source = try open(name)
            let delivered = readAll(source)
            #expect(delivered.failure != nil)
            #expect(delivered.frames > 0 && delivered.frames < RampFile.a.frames)
            #expect(deviation(delivered, of: .a) == 0)
        }

        // MARK: Reading the file

        @Test("a random access file reads where it is told, as much as there is")
        func randomAccess() throws {
            let dir = try TempDir()
            let file = try RandomAccessFile(url: dir.write("ten", Data("0123456789".utf8)))
            #expect(file.size == 10)
            var bytes = [UInt8](repeating: 0, count: 16)
            #expect(file.read(at: 0, into: &bytes, count: 4) == 4 && Array(bytes[0..<4]) == Array("0123".utf8))
            #expect(file.read(at: 8, into: &bytes, count: 4) == 2 && Array(bytes[0..<2]) == Array("89".utf8))
            #expect(file.read(at: 10, into: &bytes, count: 4) == 0)
            #expect(file.read(at: 1000, into: &bytes, count: 4) == 0)
            #expect(file.read(at: 3, into: &bytes, count: 0) == 0)

            // Anything that isn't a file has no size, and can't be read.
            let folder = try RandomAccessFile(url: dir.url)
            #expect(folder.size == -1)
            #expect(folder.read(at: 0, into: &bytes, count: 4) == -1)
            #expect(throws: (any Error).self) { try RandomAccessFile(url: dir.path("nope")) }
        }

        // MARK: Layouts

        @Test("speaker masks give the labels of the channels, in the order of the bits")
        func masks() {
            #expect(SourceFormat.labels(waveMask: 0x3F, channels: 6) == [
                kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
            ])
            #expect(SourceFormat.labels(waveMask: 0x60F, channels: 6)?.suffix(2)
                    == [kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect])
            // A file that says nothing, or something that doesn't fit, is taken to be a WAV file of that many channels.
            #expect(SourceFormat.labels(waveMask: 0, channels: 6) == SourceFormat.labels(waveMask: 0x3F, channels: 6))
            #expect(SourceFormat.labels(waveMask: 0x3, channels: 6) == SourceFormat.labels(waveMask: 0x3F, channels: 6))
            #expect(SourceFormat.labels(waveMask: 0, channels: 3) == [kAudioChannelLabel_Left, kAudioChannelLabel_Right,
                                                                      kAudioChannelLabel_Center])
            // Nothing to go by for twelve channels, or for positions that aren't known.
            #expect(SourceFormat.labels(waveMask: 0, channels: 12) == nil)
            #expect(SourceFormat.labels(waveMask: 1 << 20 | 0x3F, channels: 7) == nil)
        }

        @Test("a format for any number of channels, none for what is no audio")
        func formats() throws {
            #expect(SourceFormat.make(sampleRate: 44100, channels: 1, waveMask: 0)?.channelCount == 1)
            #expect(SourceFormat.make(sampleRate: 44100, channels: 2, waveMask: 0x3)?.channelCount == 2)
            let surround = try #require(SourceFormat.make(sampleRate: 48000, channels: 6, waveMask: 0x3F))
            #expect(surround.channelCount == 6 && surround.sampleRate == 48000 && !surround.isInterleaved)
            #expect(ChannelDownmix.labels(of: surround)?.count == 6)
            // Without labels the channels are just numbered, and mixed alternately by the downmix.
            let twelve = try #require(SourceFormat.make(sampleRate: 48000, channels: 12, waveMask: 0))
            #expect(twelve.channelCount == 12)
            #expect(SourceFormat.make(sampleRate: 48000, channels: 0, waveMask: 0) == nil)
            #expect(SourceFormat.make(sampleRate: 48000, channels: SourceFormat.maxChannels + 1, waveMask: 0) == nil)
            #expect(SourceFormat.make(sampleRate: 0, channels: 2, waveMask: 0) == nil)
        }
    }
}
