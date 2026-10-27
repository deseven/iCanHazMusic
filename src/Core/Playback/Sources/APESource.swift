// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Accelerate
import AVFoundation
import CMonkeysAudio
import Foundation

/// A Monkey's Audio file (`.ape`), decoded by the vendored SDK through our C interface (`vendor/README.md`).
///
/// - The file is read through a callback of ours (`RandomAccessFile`), so a file that doesn't answer blocks the queue
///   `TrackDecoder` runs the source on and nothing else.
/// - The length is the one in the header, which is exact. Seeking is sample-exact and needs no pre-roll.
/// - 8 to 32 bit integers and 32 bit floats come out as floats. A file made from a multichannel WAV file keeps its
///   channel mask (see `SourceFormat`).
/// - A block that fails its checksum, or one that isn't there (a truncated file), ends the audio at that point.
final class APESource: PCMSource {
    private let decoder: OpaquePointer
    // Read by the decoder until it is closed.
    private let file: RandomAccessFile

    private let channels: Int
    private let sampleRate: Double
    private let bitsPerSample: Int
    private let isFloat: Bool
    let length: Int64
    let processingFormat: AVAudioFormat
    private(set) var framePosition: Int64 = 0

    /// Interleaved samples as the decoder delivers them, and how many bytes there is room for.
    private var samples: UnsafeMutableRawPointer?
    private var samplesCapacity = 0

    init(url: URL) throws {
        let file = try RandomAccessFile(url: url)
        var reader = ichm_ape_reader(
            context: Unmanaged.passUnretained(file).toOpaque(),
            read_at: { context, offset, buffer, count in
                guard let context, let buffer, count > 0 else { return 0 }
                let file = Unmanaged<RandomAccessFile>.fromOpaque(context).takeUnretainedValue()
                return Int64(file.read(at: offset, into: buffer, count: Int(count)))
            },
            size: file.size)
        var code: Int32 = 0
        guard let decoder = ichm_ape_open(&reader, &code) else {
            throw PCMSourceError("not a Monkey's Audio file the app can read (error \(code))")
        }

        var info = ichm_ape_info()
        ichm_ape_get_info(decoder, &info)
        let channels = Int(info.channels)
        let sampleRate = Double(info.sample_rate)
        guard info.total_frames > 0 else {
            ichm_ape_close(decoder)
            throw PCMSourceError("the file has no audio")
        }
        guard [8, 16, 24, 32].contains(info.bits_per_sample),
              let format = SourceFormat.make(sampleRate: sampleRate, channels: channels, waveMask: info.channel_mask) else {
            ichm_ape_close(decoder)
            throw PCMSourceError("\(channels) channels at \(Int(sampleRate)) Hz, \(info.bits_per_sample) bit is not supported")
        }

        self.decoder = decoder
        self.file = file
        self.channels = channels
        self.sampleRate = sampleRate
        bitsPerSample = Int(info.bits_per_sample)
        isFloat = info.is_float != 0
        length = info.total_frames
        processingFormat = format
    }

    deinit {
        ichm_ape_close(decoder)
        samples?.deallocate()
    }

    /// Monkey's Audio is always lossless.
    var codec: String {
        CodecLabel.lossless("APE", bitDepth: isFloat ? 32 : bitsPerSample, isFloat: isFloat, sampleRate: sampleRate)
    }

    func seek(to frame: Int64) throws {
        guard frame >= 0, frame < length, ichm_ape_seek(decoder, frame) == 0 else {
            throw PCMSourceError("can't seek to frame \(frame) of \(length)")
        }
        framePosition = frame
    }

    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        let wanted = Int(min(frameCount, buffer.frameCapacity))
        buffer.frameLength = 0
        guard wanted > 0, let output = buffer.floatChannelData else { return }

        let bytesPerSample = bitsPerSample / 8
        let needed = wanted * channels * bytesPerSample
        if samplesCapacity < needed {
            samples?.deallocate()
            samples = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
            samplesCapacity = needed
        }
        guard let samples else { return }

        let got = ichm_ape_read(decoder, samples, Int64(wanted))
        guard got >= 0 else { throw PCMSourceError("the file is damaged (a block can't be decoded)") }
        guard got > 0 else { return }

        let count = Int(got)
        let stride = vDSP_Stride(channels)
        let n = vDSP_Length(count)
        for channel in 0..<channels {
            let out = output[channel]
            switch (isFloat, bytesPerSample) {
            case (true, _):
                var one: Float = 1
                vDSP_vsmul(samples.assumingMemoryBound(to: Float.self) + channel, stride, &one, out, 1, n)
            case (false, 1):
                // Unsigned, centred on 128.
                let source = samples.assumingMemoryBound(to: UInt8.self)
                for i in 0..<count { out[i] = (Float(source[i * channels + channel]) - 128) / 128 }
            case (false, 2):
                var scale = Float(sign: .plus, exponent: -15, significand: 1)
                vDSP_vflt16(samples.assumingMemoryBound(to: Int16.self) + channel, stride, out, 1, n)
                vDSP_vsmul(out, 1, &scale, out, 1, n)
            case (false, 3):
                let source = samples.assumingMemoryBound(to: UInt8.self)
                for i in 0..<count {
                    let at = (i * channels + channel) * 3
                    let value = Int32(source[at]) | Int32(source[at + 1]) << 8 | Int32(Int8(bitPattern: source[at + 2])) << 16
                    out[i] = Float(value) / 8_388_608
                }
            default:
                var scale = Float(sign: .plus, exponent: -31, significand: 1)
                vDSP_vflt32(samples.assumingMemoryBound(to: Int32.self) + channel, stride, out, 1, n)
                vDSP_vsmul(out, 1, &scale, out, 1, n)
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        framePosition += got
    }
}
