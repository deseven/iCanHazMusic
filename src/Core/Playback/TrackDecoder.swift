// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation

/// Decodes one audio file into the format the playback engine works with (stereo, 32 bit float, non-interleaved,
/// at the engine's sample rate), in chunks, starting at any position.
///
/// - Everything blocking (opening the file, reading, decoding) happens on the decoder's own serial queue, never on
///   the caller's thread. Each decoder has a queue of its own, so one that hangs (say, on a stalled network
///   share) can be abandoned without holding up the decoders created after it.
/// - The length is what `AVAudioFile` reports, i.e. the exact number of audio frames of the file. AVFoundation's
///   player rounds FLAC up to whole packets and plays up to 1176 frames of padding at the end; the file API does not.
/// - Channels are folded down by `ChannelDownmix`, the sample rate is converted by `AVAudioConverter` at the
///   given `ResampleQuality` (`.high` unless told otherwise; the frame counts come out exact at every quality, so
///   the playback position stays correct). A file whose rate already is the engine's is passed through untouched.
///   `.max` costs ~25% more in the converter for no audible gain, see `dev-docs/playback.md`.
/// - A track can be a part of the file (`endSeconds`, and a `startSeconds` that is where the part starts, for the tracks of
///   a CUE sheet): decoding stops at the end frame, and a part that lies beyond the end of the file fails instead of
///   playing its last frame.
/// - A read error in the middle of a file ends the track there (`Result.finished` with a warning); only a file that
///   yields no audio at all is a failure.
/// - Whoever waits in `next()` is never held up by a file that doesn't respond: `cancel()` releases the wait at once,
///   and a call that gets no answer within its `timeout` gives up (`.failed` if nothing was delivered yet, else
///   `.finished` with a warning, i.e. the track ends there). The blocked read itself can't be interrupted: it
///   finishes in the background whenever the system lets it, and its result is dropped.
final class TrackDecoder: @unchecked Sendable {
    /// One piece of audio, ready to be scheduled on the player node.
    struct Chunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        /// Length of the whole file, in seconds.
        let fileDuration: Double
        /// Format description of the file, see `CodecLabel`.
        let codec: String
    }

    enum Result: Sendable {
        case chunk(Chunk)
        /// Everything was delivered. `warning` is set if the file ended earlier than it announced.
        case finished(warning: String?)
        /// The file can't be opened or has no audio.
        case failed(String)
    }

    private struct DecoderError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Source frames read at once.
    static let blockFrames = 8192

    let url: URL
    private let startSeconds: Double
    private let endSeconds: Double?
    private let isPart: Bool
    private let outputFormat: AVAudioFormat
    private let resampleQuality: ResampleQuality
    private let queue = DispatchQueue(label: "wtf.d7.icanhazmusic.decoder", qos: .userInitiated)

    /// Guards `cancelled`, `waiting` and `delivered`, which are touched from the caller, the queue and timers.
    private let stateLock = NSLock()
    private var cancelled = false
    /// The `next()` call in progress.
    private var waiting: Waiter?
    /// Some audio has been handed out.
    private var delivered = false

    // Only touched on `queue` from here on.
    private var opened = false
    private var finished = false
    private var file: AVAudioFile?
    private var fileDuration: Double = 0
    /// The frame (of the file) decoding stops at: the end of the track, or of the file.
    private var endFrame: Int64 = 0
    private var codec = ""
    private var downmix: ChannelDownmix?
    private var readBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var sourceExhausted = false
    private var converterDone = false
    private var warning: String?

    /// `startSeconds` and `endSeconds` are positions in the file. `isPart`: the track is a part of the file, so one that
    /// is not in the file at all is an error (a whole file starts at its last frame at the latest).
    init(url: URL, startSeconds: Double, endSeconds: Double? = nil, isPart: Bool = false, outputFormat: AVAudioFormat,
         resampleQuality: ResampleQuality = .default) {
        self.url = url
        self.startSeconds = max(0, startSeconds)
        self.endSeconds = endSeconds
        self.isPart = isPart || endSeconds != nil
        self.outputFormat = outputFormat
        self.resampleQuality = resampleQuality
    }

    /// Abandons the decoder: a `next()` call that is waiting returns `.finished` at once, nothing new is started (the
    /// blocking work in progress, if any, finishes in the background).
    func cancel() {
        stateLock.lock()
        cancelled = true
        let waiter = waiting
        waiting = nil
        stateLock.unlock()
        waiter?.resume(.finished(warning: nil))
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    /// The next chunk of audio. Calls are meant to be made one after the other, not concurrently.
    /// `timeout`: seconds to wait for the file at most; after that the decoder gives up for good (see above).
    func next(timeout: Double? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation)
            stateLock.lock()
            guard !cancelled else {
                stateLock.unlock()
                waiter.resume(.finished(warning: nil))
                return
            }
            waiting = waiter
            stateLock.unlock()

            if let timeout {
                let timer = DispatchWorkItem { [weak self] in self?.timedOut(waiter, after: timeout) }
                if waiter.arm(timer) {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                }
            }
            queue.async {
                let result = self.produce()
                self.stateLock.lock()
                if case .chunk = result { self.delivered = true }
                if self.waiting === waiter { self.waiting = nil }
                self.stateLock.unlock()
                waiter.resume(result)
            }
        }
    }

    /// The call `waiter` stands for got no answer in time: the file is given up.
    private func timedOut(_ waiter: Waiter, after seconds: Double) {
        stateLock.lock()
        guard waiting === waiter else {
            stateLock.unlock()
            return
        }
        waiting = nil
        cancelled = true
        let hadAudio = delivered
        stateLock.unlock()

        let wait = "no answer from the file in \(Int(seconds.rounded())) s"
        waiter.resume(hadAudio
            ? .finished(warning: "\(wait), the track ends here (network share or drive unavailable?)")
            : .failed("\(wait) (network share or drive unavailable?)"))
    }

    /// Resumes the continuation of a `next()` call exactly once: with the result, on `cancel()` or on the timeout.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        private var timer: DispatchWorkItem?

        init(_ continuation: CheckedContinuation<Result, Never>) { self.continuation = continuation }

        /// Keeps the timeout to cancel it on `resume`. False if that has happened already (the timer isn't needed).
        func arm(_ timer: DispatchWorkItem) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard continuation != nil else { return false }
            self.timer = timer
            return true
        }

        func resume(_ result: Result) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let timer = self.timer
            self.timer = nil
            lock.unlock()
            timer?.cancel()
            continuation?.resume(returning: result)
        }
    }

    // MARK: - On the queue

    private func produce() -> Result {
        if finished || isCancelled { return .finished(warning: nil) }
        if !opened {
            do {
                try open()
            } catch {
                finished = true
                if !FileManager.default.fileExists(atPath: url.path) {
                    return .failed("file not found (moved, renamed, or volume unavailable?)")
                }
                return .failed(error.localizedDescription)
            }
        }
        do {
            if let buffer = try makeChunk() {
                return .chunk(Chunk(buffer: buffer, fileDuration: fileDuration, codec: codec))
            }
        } catch {
            warning = warning ?? error.localizedDescription
        }
        finished = true
        return .finished(warning: warning)
    }

    private func open() throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0 else { throw DecoderError("the file has no audio") }

        self.file = file
        fileDuration = Double(file.length) / format.sampleRate
        codec = CodecLabel.make(url: url, fileFormat: file.fileFormat)
        downmix = ChannelDownmix(format: format)
        readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.blockFrames))

        if format.sampleRate != outputFormat.sampleRate {
            guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                             channels: 2, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: outputFormat) else {
                throw DecoderError("can't convert \(Int(format.sampleRate)) Hz to \(Int(outputFormat.sampleRate)) Hz")
            }
            converter.sampleRateConverterQuality = resampleQuality.avQuality.rawValue
            converterSourceFormat = source
            self.converter = converter
        }

        endFrame = file.length
        if let endSeconds { endFrame = min(file.length, max(0, Int64((endSeconds * format.sampleRate).rounded()))) }
        var start = max(Int64((startSeconds * format.sampleRate).rounded()), 0)
        if isPart {
            guard start < endFrame else { throw DecoderError("the track lies beyond the end of the file") }
        } else {
            // A position past the end plays the last frame, not nothing.
            start = min(start, file.length - 1)
        }
        if start > 0 { file.framePosition = start }
        opened = true

        let channels = format.channelCount == 2 ? "stereo" : "\(format.channelCount) ch -> stereo"
        let conversion = converter == nil
            ? "no resampling"
            : "resampled to \(Int(outputFormat.sampleRate)) Hz (\(resampleQuality.rawValue) quality)"
        var from = start > 0 ? ", from \(String(format: "%.1f", Double(start) / format.sampleRate)) s" : ""
        if endFrame < file.length { from += " to \(String(format: "%.1f", Double(endFrame) / format.sampleRate)) s" }
        Log.info("decoder: opened \(url.path): \(codec), \(Int(format.sampleRate)) Hz, \(channels), "
            + "\(String(format: "%.1f", fileDuration)) s, \(conversion)\(from)")
    }

    private func makeChunk() throws -> AVAudioPCMBuffer? {
        guard let converter else {
            return readBlock(into: outputFormat)
        }

        let capacity = AVAudioFrameCount(Self.blockFrames * 2)
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
        // The converter may hand out nothing while it is still filling its internal buffers.
        for _ in 0..<16 {
            if sourceExhausted && converterDone { return nil }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [self] _, inputStatus in
                if sourceExhausted {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let block = readBlock(into: converterSourceFormat!) else {
                    sourceExhausted = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return block
            }
            switch status {
            case .error:
                throw error ?? DecoderError("sample rate conversion failed")
            case .endOfStream:
                converterDone = true
            case .haveData, .inputRanDry:
                break
            @unknown default:
                break
            }
            if output.frameLength > 0 { return output }
            if converterDone { return nil }
        }
        return nil
    }

    /// The next block of the file, folded down to stereo in `format`; `nil` at the end (or at an error).
    private func readBlock(into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file, let readBuffer, let downmix else { return nil }
        let remaining = endFrame - file.framePosition
        guard remaining > 0 else { return nil }

        do {
            try file.read(into: readBuffer, frameCount: AVAudioFrameCount(min(Int64(Self.blockFrames), remaining)))
        } catch {
            warning = "decoding stopped after \(file.framePosition) of \(endFrame) frames: \(error.localizedDescription)"
            return nil
        }
        guard readBuffer.frameLength > 0 else {
            warning = "the file ends after \(file.framePosition) of \(endFrame) frames"
            return nil
        }

        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readBuffer.frameLength)!
        downmix.apply(readBuffer, to: block)
        return block
    }
}
