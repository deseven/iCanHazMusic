// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Accelerate
import AVFoundation
import Foundation

/// What a pass over a file found.
struct WaveformAnalysis: Equatable, Sendable {
    let waveform: Waveform
    /// False if a read failed (or the file ended early) in the middle: the buckets after that point are 0. Such a
    /// result is shown, but not stored: a network hiccup must not leave a truncated waveform in the cache.
    let isComplete: Bool
}

/// A flag one thread sets and another polls.
final class WaveformCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Reads a whole file once and measures everything the seek bar styles show (`Waveform`) in `Waveform.bucketCount`
/// equal buckets: RMS, peak, the power in `Waveform.bandCount` frequency bands, and from those the sections of the track.
///
/// - The file is read at its own rate and not resampled (useless here, and it costs CPU); channels are folded to stereo
///   by `ChannelDownmix`. The RMS of a bucket is `sqrt((sum(L^2) + sum(R^2)) / (2 * frames))`, summed in `Double`; the
///   peak is the largest sample of either channel.
/// - **Spectrum**: of the mono mix `(L + R) / 2`, 4096 point Hann windowed FFTs. Frame *starts* lie on one grid for the whole
///   file (multiples of `hop`, which depends on the bucket length only) and a frame belongs to the bucket its start is in;
///   so the result doesn't depend on how the work is split. The band powers of a bucket are the mean over its frames,
///   scaled so the bands add up to the mean square of the mono signal (a bucket with no frame, in a very short track or
///   in the last 4096 frames of one, takes its neighbour's). Bands are log spaced from 40 Hz to 16 kHz (`SpectralLayout`).
/// - The buckets are split into `workers` contiguous slices; each worker has its own `AVAudioFile`, seeked to the start
///   of its slice, and reads 4096 frames past the end of it for the last frames of the slice.
/// - Decoding is nearly all of the cost (the spectrum adds about 15%), see `dev-docs/playback.md` for numbers. The pass
///   runs on a queue of its own at `.utility`, not on the Swift concurrency pool: reads blocked on a stalled network share
///   would eat its threads.
/// - A pass can be cancelled; a read that is blocked on the network can't be interrupted, it ends when the read returns
///   and its result is dropped.
enum WaveformAnalyzer {
    /// Parallel readers of one file.
    static let workers = 2
    /// Frames read at once.
    static let blockFrames = 16_384

    /// Measures `url` on a background queue. `nil` if the file doesn't open, has no audio, or the task is cancelled.
    static func analyse(url: URL) async -> WaveformAnalysis? {
        let cancellation = WaveformCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let queue = DispatchQueue(label: "wtf.d7.icanhazmusic.waveform", qos: .utility, attributes: .concurrent)
                queue.async {
                    continuation.resume(returning: analyse(url: url, workers: workers) { cancellation.isCancelled })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Measures `url` on the calling thread (and `workers` threads of the pool). `nil` if the file doesn't open, has no
    /// audio, or `isCancelled` said yes.
    static func analyse(url: URL, workers: Int, isCancelled: @escaping @Sendable () -> Bool) -> WaveformAnalysis? {
        guard let first = try? AVAudioFile(forReading: url),
              first.length > 0, first.processingFormat.sampleRate > 0 else { return nil }
        let length = first.length
        let sampleRate = first.processingFormat.sampleRate
        let bucketFrames = (length + Int64(Waveform.bucketCount) - 1) / Int64(Waveform.bucketCount)
        let buckets = Int((length + bucketFrames - 1) / bucketFrames)
        let slices = max(1, min(workers, buckets))
        // About two frames per bucket where there is room, a frame every 256 at the closest.
        let hop = Int(max(SpectralLayout.minHop, min(SpectralLayout.maxHop, bucketFrames / 2)))

        let collector = SliceCollector(count: slices)
        let firstFile = FileBox(first)
        DispatchQueue.concurrentPerform(iterations: slices) { index in
            let start = index * buckets / slices
            let end = (index + 1) * buckets / slices
            let result: Slice
            if isCancelled() {
                result = .cancelled
            } else {
                var file = index == 0 ? firstFile.take() : nil
                if file == nil { file = try? AVAudioFile(forReading: url) }
                if let file {
                    result = measure(file, buckets: start..<end, bucketFrames: bucketFrames, hop: hop, isCancelled: isCancelled)
                } else {
                    result = Slice(buckets: end - start, isComplete: false)
                }
            }
            collector.set(result, at: index)
        }

        let parts = collector.results
        guard !isCancelled(), !parts.contains(where: \.wasCancelled) else { return nil }

        let sums = parts.flatMap(\.sums)
        let frames = parts.flatMap(\.frames)
        let peaks = parts.flatMap(\.peaks)
        // A bucket is measured over the frames that were read of it: all of them, except where a file ends earlier than
        // it announced or a format seeks a little late (Vorbis by 20 ms), which leaves the last bucket of a slice short.
        var rms: [UInt8] = []
        rms.reserveCapacity(buckets)
        for (sum, count) in zip(sums, frames) {
            rms.append(count > 0 ? Waveform.level(forRMS: (sum / Double(2 * count)).squareRoot()) : 0)
        }
        let peak = peaks.map { Waveform.level(forRMS: Double($0)) }

        let spectrum = Spectrum(parts: parts, buckets: buckets)
        let seconds = Double(length) / sampleRate
        var rmsDB = [Float](repeating: -120, count: buckets)
        for (i, (sum, count)) in zip(sums, frames).enumerated() where count > 0 && sum > 0 {
            rmsDB[i] = Float(10 * log10(sum / Double(2 * count)))
        }
        let structure = WaveformStructureAnalyzer.analyse(rmsDB: rmsDB, bandDB: spectrum.bandDB, bands: Waveform.bandCount,
                                                          chroma: spectrum.chroma, seconds: seconds)
        guard !isCancelled() else { return nil }

        let waveform = Waveform(rms: rms, peak: peak, bands: spectrum.storedBands(), structure: structure)
        return WaveformAnalysis(waveform: waveform, isComplete: parts.allSatisfy(\.isComplete))
    }

    // MARK: - One worker

    private struct Slice {
        /// Sum of the squares of both channels, per bucket of the slice.
        var sums: [Double]
        /// How many frames went into each of the sums.
        var frames: [Int64]
        /// Largest sample of either channel.
        var peaks: [Float]
        /// FFT frames per bucket, the sums of their band powers (`bandCount` per bucket) and pitch classes (12 per bucket).
        var fftFrames: [Int32]
        var bandPower: [Float]
        var chroma: [Float]
        var isComplete: Bool
        var wasCancelled: Bool

        init(buckets: Int, isComplete: Bool = true, wasCancelled: Bool = false) {
            sums = [Double](repeating: 0, count: buckets)
            frames = [Int64](repeating: 0, count: buckets)
            peaks = [Float](repeating: 0, count: buckets)
            fftFrames = [Int32](repeating: 0, count: buckets)
            bandPower = [Float](repeating: 0, count: buckets * Waveform.bandCount)
            chroma = [Float](repeating: 0, count: buckets * SpectralLayout.chromaCount)
            self.isComplete = isComplete
            self.wasCancelled = wasCancelled
        }

        static let cancelled = Slice(buckets: 0, isComplete: false, wasCancelled: true)
    }

    private static func measure(_ file: AVAudioFile, buckets: Range<Int>, bucketFrames: Int64, hop: Int,
                                isCancelled: () -> Bool) -> Slice {
        let format = file.processingFormat
        let downmix = ChannelDownmix(format: format)
        var slice = Slice(buckets: buckets.count)

        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(blockFrames)) else {
            slice.isComplete = false
            return slice
        }
        var mixBuffer: AVAudioPCMBuffer?
        if !downmix.isStereoCopy {
            guard let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                             channels: 2, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(blockFrames)) else {
                slice.isComplete = false
                return slice
            }
            mixBuffer = buffer
        }

        let spectral = SpectralProcessor(sampleRate: format.sampleRate)
        let fftSize = SpectralLayout.fftSize

        let startFrame = Int64(buckets.lowerBound) * bucketFrames
        let endFrame = min(file.length, Int64(buckets.upperBound) * bucketFrames)
        // The last frames of the slice need the next `fftSize` frames of the file.
        let readEnd = min(file.length, endFrame + Int64(fftSize))
        // `framePosition` raises an Objective-C exception outside 0..<length; a slice starts inside by construction.
        if startFrame > 0, startFrame < file.length { file.framePosition = startFrame }

        var mono = [Float](repeating: 0, count: blockFrames)
        var pending: [Float] = []
        pending.reserveCapacity(blockFrames + 2 * fftSize)
        var pendingBase = startFrame
        let hopLength = Int64(hop)
        var nextFrame = (startFrame + hopLength - 1) / hopLength * hopLength

        var position = startFrame
        while position < readEnd {
            if isCancelled() { return .cancelled }
            let wanted = AVAudioFrameCount(min(Int64(blockFrames), readEnd - position))
            do {
                try file.read(into: readBuffer, frameCount: wanted)
            } catch {
                slice.isComplete = false
                break
            }
            let got = Int(readBuffer.frameLength)
            guard got > 0 else {
                // The file ends before it said it would: a short tail is no reason to distrust the rest.
                slice.isComplete = endFrame - position <= max(bucketFrames, file.length / 50)
                break
            }

            let source: AVAudioPCMBuffer
            if let mixBuffer {
                downmix.apply(readBuffer, to: mixBuffer)
                source = mixBuffer
            } else {
                source = readBuffer
            }
            guard let data = source.floatChannelData else {
                slice.isComplete = false
                break
            }

            // Time domain, up to the end of the slice.
            let timeFrames = Int(max(0, min(Int64(got), endFrame - position)))
            var offset = 0
            while offset < timeFrames {
                let absolute = position + Int64(offset)
                let bucket = Int(absolute / bucketFrames)
                let count = min(timeFrames - offset, Int(Int64(bucket + 1) * bucketFrames - absolute))
                var left: Float = 0
                var right: Float = 0
                vDSP_svesq(data[0] + offset, 1, &left, vDSP_Length(count))
                vDSP_svesq(data[1] + offset, 1, &right, vDSP_Length(count))
                var leftPeak: Float = 0
                var rightPeak: Float = 0
                vDSP_maxmgv(data[0] + offset, 1, &leftPeak, vDSP_Length(count))
                vDSP_maxmgv(data[1] + offset, 1, &rightPeak, vDSP_Length(count))
                let index = bucket - buckets.lowerBound
                slice.sums[index] += Double(left) + Double(right)
                slice.frames[index] += Int64(count)
                slice.peaks[index] = max(slice.peaks[index], leftPeak, rightPeak)
                offset += count
            }

            // Frequency domain: the frames that start in this slice and fit into what was read.
            var half: Float = 0.5
            mono.withUnsafeMutableBufferPointer { vDSP_vasm(data[0], 1, data[1], 1, &half, $0.baseAddress!, 1, vDSP_Length(got)) }
            pending.append(contentsOf: mono[0..<got])
            while nextFrame < endFrame, nextFrame + Int64(fftSize) <= pendingBase + Int64(pending.count) {
                let bucket = Int(nextFrame / bucketFrames) - buckets.lowerBound
                pending.withUnsafeBufferPointer { spectral.process($0.baseAddress! + Int(nextFrame - pendingBase)) }
                slice.fftFrames[bucket] += 1
                for b in 0..<Waveform.bandCount { slice.bandPower[bucket * Waveform.bandCount + b] += spectral.bandPower[b] }
                for k in 0..<SpectralLayout.chromaCount { slice.chroma[bucket * SpectralLayout.chromaCount + k] += spectral.chroma[k] }
                nextFrame += hopLength
            }
            let consumed = min(Int(nextFrame - pendingBase), pending.count)
            if consumed > 1 << 16 {
                pending.removeFirst(consumed)
                pendingBase += Int64(consumed)
            }
            position += Int64(got)
        }
        return slice
    }

    // MARK: - Putting the slices together

    /// The spectral data of all buckets, with buckets that had no frame filled from their neighbours.
    private struct Spectrum {
        /// Mean band power per bucket (linear, mean square of the mono mix), `bandCount` per bucket.
        var power: [Float]
        /// Mean pitch class strengths per bucket, 12 per bucket.
        var chroma: [Float]
        let buckets: Int

        init(parts: [Slice], buckets: Int) {
            self.buckets = buckets
            let bandCount = Waveform.bandCount
            let chromaCount = SpectralLayout.chromaCount
            let frames = parts.flatMap(\.fftFrames)
            var power = parts.flatMap(\.bandPower)
            var chroma = parts.flatMap(\.chroma)
            var filled = [Bool](repeating: false, count: buckets)
            for i in 0..<buckets where frames[i] > 0 {
                let divisor = Float(frames[i])
                for b in 0..<bandCount { power[i * bandCount + b] /= divisor }
                for k in 0..<chromaCount { chroma[i * chromaCount + k] /= divisor }
                filled[i] = true
            }
            // Forward fill from the last bucket that has frames, then backward for the ones before the first.
            var last: Int?
            for i in 0..<buckets {
                if filled[i] { last = i; continue }
                guard let source = last else { continue }
                for b in 0..<bandCount { power[i * bandCount + b] = power[source * bandCount + b] }
                for k in 0..<chromaCount { chroma[i * chromaCount + k] = chroma[source * chromaCount + k] }
            }
            if let firstFilled = filled.firstIndex(of: true) {
                for i in 0..<firstFilled {
                    for b in 0..<bandCount { power[i * bandCount + b] = power[firstFilled * bandCount + b] }
                    for k in 0..<chromaCount { chroma[i * chromaCount + k] = chroma[firstFilled * chromaCount + k] }
                }
            }
            self.power = power
            self.chroma = chroma
        }

        /// dB of the power per band and bucket, for the structure analysis.
        var bandDB: [Float] {
            power.map { 10 * log10f($0 + 1e-12) }
        }

        /// The stored form: levels of the power, two buckets to a column (their mean).
        func storedBands() -> [UInt8] {
            let bandCount = Waveform.bandCount
            let columns = Waveform.bandColumnCount(forBuckets: buckets)
            var result = [UInt8](repeating: 0, count: columns * bandCount)
            for column in 0..<columns {
                let first = column * 2
                let second = min(buckets - 1, first + 1)
                for b in 0..<bandCount {
                    let mean = (Double(power[first * bandCount + b]) + Double(power[second * bandCount + b])) / 2
                    result[column * bandCount + b] = Waveform.bandLevel(forPower: mean)
                }
            }
            return result
        }
    }

    // MARK: - Sharing between the workers

    private final class SliceCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var slices: [Slice?]

        init(count: Int) {
            slices = [Slice?](repeating: nil, count: count)
        }

        func set(_ slice: Slice, at index: Int) {
            lock.lock()
            slices[index] = slice
            lock.unlock()
        }

        var results: [Slice] {
            lock.lock()
            defer { lock.unlock() }
            return slices.compactMap { $0 }
        }
    }

    /// The file that was opened to learn the length, handed to the first worker so it isn't opened twice (over a
    /// network share, opening is the slow part).
    private final class FileBox: @unchecked Sendable {
        private let lock = NSLock()
        private var file: AVAudioFile?

        init(_ file: AVAudioFile) {
            self.file = file
        }

        func take() -> AVAudioFile? {
            lock.lock()
            defer { lock.unlock() }
            defer { file = nil }
            return file
        }
    }
}
