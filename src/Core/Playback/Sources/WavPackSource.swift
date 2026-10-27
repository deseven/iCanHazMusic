// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Accelerate
import AVFoundation
import CWavPack
import Foundation

/// A WavPack file (`.wv`), decoded by the vendored libwavpack (`vendor/README.md`).
///
/// - The file is read through callbacks of ours (`RandomAccessFile`), so a file that doesn't answer blocks the queue
///   `TrackDecoder` runs the source on and nothing else. The library is opened without `OPEN_TAGS`: it reads nothing
///   but the blocks of audio (the tags are read by `ApeTag`).
/// - The length is the one in the header, which is exact. Seeking is sample-exact and needs no pre-roll.
/// - A hybrid file (`.wv` lossy, with a `.wvc` correction file next to it) is decoded lossless if the `.wvc` is there,
///   else as the lossy audio it is.
/// - 8 to 32 bit integers and 32 bit floats (normalised to +-1) come out as floats; DSD is decoded to PCM (the library
///   decimates it, 24 bit at 1/8 of the one-bit rate: DSD64 gives 352.8 kHz).
/// - A block that fails its checksum, or one that isn't there (a truncated file), ends the audio at that point.
final class WavPackSource: PCMSource {
    private let context: OpaquePointer
    // Referred to by the library until it is closed.
    private let main: Stream
    private let correction: Stream?

    private let channels: Int
    private let sampleRate: Double
    private let bitsPerSample: Int
    private let mode: Int32
    private let isFloat: Bool
    /// The rate of the one-bit stream of a DSD file; the same as `sampleRate` for anything else.
    private let nativeRate: Double
    let length: Int64
    let processingFormat: AVAudioFormat
    private(set) var framePosition: Int64 = 0

    /// Interleaved samples as the library delivers them.
    private var samples: [Int32] = []

    init(url: URL) throws {
        let main = Stream(file: try RandomAccessFile(url: url))
        // A hybrid file's correction file: the name with a "c" more ("C" after an upper case extension, as the library's
        // own file functions have it). Whether it is needed, only the file knows; if it isn't there, there is none.
        let correctionURL = URL(fileURLWithPath: url.path + (url.pathExtension.last?.isUppercase == true ? "C" : "c"))
        let correction = (try? RandomAccessFile(url: correctionURL)).map(Stream.init)

        var error = [CChar](repeating: 0, count: 81)
        let flags = OPEN_NORMALIZE | OPEN_DSD_AS_PCM
        guard let context = WavpackOpenFileInputEx64(Self.reader, Unmanaged.passUnretained(main).toOpaque(),
                                                     correction.map { Unmanaged.passUnretained($0).toOpaque() }, &error,
                                                     flags, 0) else {
            throw PCMSourceError("not a WavPack file the app can read: \(String(cString: error))")
        }

        let channels = Int(WavpackGetNumChannels(context))
        let sampleRate = Double(WavpackGetSampleRate(context))
        let mode = WavpackGetMode(context)
        let length = WavpackGetNumSamples64(context)
        let bits = Int(WavpackGetBitsPerSample(context))
        // An unknown length (a stream that was never finished) is not a file to play: where it ends isn't known.
        guard length > 0 else {
            WavpackCloseFile(context)
            throw PCMSourceError(length == 0 ? "the file has no audio" : "the length of the file is unknown")
        }
        guard bits >= 1, bits <= 32,
              let format = SourceFormat.make(sampleRate: sampleRate, channels: channels,
                                             waveMask: UInt32(truncatingIfNeeded: WavpackGetChannelMask(context))) else {
            WavpackCloseFile(context)
            throw PCMSourceError("\(channels) channels at \(Int(sampleRate)) Hz, \(bits) bit is not supported")
        }

        self.context = context
        self.main = main
        self.correction = correction
        self.channels = channels
        self.sampleRate = sampleRate
        self.mode = mode
        self.length = length
        bitsPerSample = bits
        isFloat = mode & MODE_FLOAT != 0
        nativeRate = Double(WavpackGetNativeSampleRate(context))
        processingFormat = format
    }

    deinit {
        WavpackCloseFile(context)
    }

    var codec: String {
        if nativeRate != sampleRate {
            return "WV DSD\(Int((nativeRate / 44100).rounded()))"
        }
        if mode & MODE_LOSSLESS != 0 {
            return CodecLabel.lossless("WV", bitDepth: isFloat ? 32 : bitsPerSample, isFloat: isFloat, sampleRate: sampleRate)
        }
        return CodecLabel.lossy("WV", bitsPerSecond: WavpackGetAverageBitrate(context, 0))
    }

    func seek(to frame: Int64) throws {
        guard frame >= 0, frame < length, WavpackSeekSample64(context, frame) != 0 else {
            throw PCMSourceError("can't seek to frame \(frame) of \(length)")
        }
        framePosition = frame
    }

    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        let wanted = Int(min(frameCount, buffer.frameCapacity))
        buffer.frameLength = 0
        guard wanted > 0, let output = buffer.floatChannelData else { return }
        if samples.count < wanted * channels { samples = [Int32](repeating: 0, count: wanted * channels) }

        let got = Int(samples.withUnsafeMutableBufferPointer { WavpackUnpackSamples(context, $0.baseAddress, UInt32(wanted)) })
        if WavpackGetNumErrors(context) > 0 {
            throw PCMSourceError("a block of the file is damaged (it fails its checksum)")
        }
        guard got > 0 else { return }

        samples.withUnsafeBufferPointer { interleaved in
            let stride = vDSP_Stride(channels)
            let count = vDSP_Length(got)
            for channel in 0..<channels {
                if isFloat {
                    // The library hands out the bits of the floats.
                    var one: Float = 1
                    interleaved.baseAddress!.withMemoryRebound(to: Float.self, capacity: got * channels) {
                        vDSP_vsmul($0 + channel, stride, &one, output[channel], 1, count)
                    }
                } else {
                    // Right-justified integers of `bitsPerSample` bits; a power of two scales them exactly.
                    var scale = Float(sign: .plus, exponent: -(bitsPerSample - 1), significand: 1)
                    vDSP_vflt32(interleaved.baseAddress! + channel, stride, output[channel], 1, count)
                    vDSP_vsmul(output[channel], 1, &scale, output[channel], 1, count)
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(got)
        framePosition += Int64(got)
    }

    // MARK: Reading the file for the library

    /// A file as the library sees it: a position, and the bytes at it.
    private final class Stream {
        let file: RandomAccessFile
        var position: Int64 = 0

        init(file: RandomAccessFile) { self.file = file }

        static func from(_ id: UnsafeMutableRawPointer?) -> Stream {
            Unmanaged<Stream>.fromOpaque(id!).takeUnretainedValue()
        }
    }

    /// The callbacks, one set for all files; what they work on comes with every call.
    private static let reader: UnsafeMutablePointer<WavpackStreamReader64> = {
        let reader = UnsafeMutablePointer<WavpackStreamReader64>.allocate(capacity: 1)
        reader.initialize(to: WavpackStreamReader64(
            read_bytes: { id, data, count in
                let stream = Stream.from(id)
                guard let data, count > 0 else { return 0 }
                // An error is read as the end of the file: the library stops there.
                let got = stream.file.read(at: stream.position, into: data, count: Int(count))
                guard got > 0 else { return 0 }
                stream.position += Int64(got)
                return Int32(got)
            },
            write_bytes: nil,
            get_pos: { id in Stream.from(id).position },
            set_pos_abs: { id, position in
                guard position >= 0 else { return -1 }
                Stream.from(id).position = position
                return 0
            },
            set_pos_rel: { id, delta, mode in
                let stream = Stream.from(id)
                let base: Int64
                switch mode {
                case SEEK_SET: base = 0
                case SEEK_CUR: base = stream.position
                case SEEK_END:
                    guard stream.file.size >= 0 else { return -1 }
                    base = stream.file.size
                default: return -1
                }
                guard base + delta >= 0 else { return -1 }
                stream.position = base + delta
                return 0
            },
            // The byte that was read last is still in the file: reading it again is pushing it back.
            push_back_byte: { id, byte in
                Stream.from(id).position -= 1
                return byte
            },
            get_length: { id in max(0, Stream.from(id).file.size) },
            can_seek: { id in Stream.from(id).file.size >= 0 ? 1 : 0 },
            truncate_here: nil,
            close: nil))
        return reader
    }()
}
