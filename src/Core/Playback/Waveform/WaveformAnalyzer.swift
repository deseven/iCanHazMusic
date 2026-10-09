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

/// Reads a whole file and measures its loudness over time (`Waveform`): the RMS of `Waveform.bucketCount` equal slices.
///
/// - The file is read at its own rate and not resampled (useless here, and it costs CPU); channels are folded to stereo
///   by `ChannelDownmix`. The RMS of a bucket is `sqrt((sum(L^2) + sum(R^2)) / (2 * frames))`, summed in `Double`.
/// - The buckets are split into `workers` contiguous slices; each worker has its own `AVAudioFile`, seeked to the start
///   of its slice. The result doesn't depend on the number of workers.
/// - Decoding is nearly all of the cost, see `dev-docs/playback.md` for numbers. The pass runs on a queue of its own at
///   `.utility`, not on the Swift concurrency pool: reads blocked on a stalled network share would eat its threads.
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
        let bucketFrames = (length + Int64(Waveform.bucketCount) - 1) / Int64(Waveform.bucketCount)
        let buckets = Int((length + bucketFrames - 1) / bucketFrames)
        let slices = max(1, min(workers, buckets))

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
                    result = measure(file, buckets: start..<end, bucketFrames: bucketFrames, isCancelled: isCancelled)
                } else {
                    result = Slice(buckets: end - start, isComplete: false)
                }
            }
            collector.set(result, at: index)
        }

        let parts = collector.results
        guard !isCancelled(), !parts.contains(where: \.wasCancelled) else { return nil }

        var levels: [UInt8] = []
        levels.reserveCapacity(buckets)
        // A bucket is measured over the frames that were read of it: all of them, except where a file ends earlier than
        // it announced or a format seeks a little late (Vorbis by 20 ms), which leaves the last bucket of a slice short.
        for (sum, frames) in zip(parts.flatMap(\.sums), parts.flatMap(\.frames)) {
            levels.append(frames > 0 ? Waveform.level(forRMS: (sum / Double(2 * frames)).squareRoot()) : 0)
        }
        return WaveformAnalysis(waveform: Waveform(levels: levels), isComplete: parts.allSatisfy(\.isComplete))
    }

    // MARK: - One worker

    private struct Slice {
        /// Sum of the squares of both channels, per bucket of the slice.
        var sums: [Double]
        /// How many frames went into each of the sums.
        var frames: [Int64]
        var isComplete: Bool
        var wasCancelled: Bool

        init(buckets: Int, isComplete: Bool = true, wasCancelled: Bool = false) {
            sums = [Double](repeating: 0, count: buckets)
            frames = [Int64](repeating: 0, count: buckets)
            self.isComplete = isComplete
            self.wasCancelled = wasCancelled
        }

        static let cancelled = Slice(buckets: 0, isComplete: false, wasCancelled: true)
    }

    private static func measure(_ file: AVAudioFile, buckets: Range<Int>, bucketFrames: Int64,
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

        let startFrame = Int64(buckets.lowerBound) * bucketFrames
        let endFrame = min(file.length, Int64(buckets.upperBound) * bucketFrames)
        // `framePosition` raises an Objective-C exception outside 0..<length; a slice starts inside by construction.
        if startFrame > 0, startFrame < file.length { file.framePosition = startFrame }

        var position = startFrame
        while position < endFrame {
            if isCancelled() { return .cancelled }
            let wanted = AVAudioFrameCount(min(Int64(blockFrames), endFrame - position))
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

            var offset = 0
            while offset < got {
                let absolute = position + Int64(offset)
                let bucket = Int(absolute / bucketFrames)
                let count = min(got - offset, Int(Int64(bucket + 1) * bucketFrames - absolute))
                var left: Float = 0
                var right: Float = 0
                vDSP_svesq(data[0] + offset, 1, &left, vDSP_Length(count))
                vDSP_svesq(data[1] + offset, 1, &right, vDSP_Length(count))
                slice.sums[bucket - buckets.lowerBound] += Double(left) + Double(right)
                slice.frames[bucket - buckets.lowerBound] += Int64(count)
                offset += count
            }
            position += Int64(got)
        }
        return slice
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
