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
/// - Channels are folded down by `ChannelDownmix`, the sample rate is converted by `AVAudioConverter` at its
///   highest quality (the frame counts come out exact, so the playback position stays correct). A file whose rate
///   already is the engine's is passed through untouched.
/// - A read error in the middle of a file ends the track there (`Result.finished` with a warning); only a file that
///   yields no audio at all is a failure.
final class TrackDecoder: @unchecked Sendable {
    /// One piece of audio, ready to be scheduled on the player node.
    struct Chunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        /// Length of the whole file, in seconds.
        let fileDuration: Double
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
    private let outputFormat: AVAudioFormat
    private let queue = DispatchQueue(label: "wtf.d7.icanhazmusic.decoder", qos: .userInitiated)

    private let cancelLock = NSLock()
    private var cancelled = false

    // Only touched on `queue` from here on.
    private var opened = false
    private var finished = false
    private var file: AVAudioFile?
    private var fileDuration: Double = 0
    private var downmix: ChannelDownmix?
    private var readBuffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var sourceExhausted = false
    private var converterDone = false
    private var warning: String?

    init(url: URL, startSeconds: Double, outputFormat: AVAudioFormat) {
        self.url = url
        self.startSeconds = max(0, startSeconds)
        self.outputFormat = outputFormat
    }

    /// Abandons the decoder: the work in progress finishes, nothing new is started.
    func cancel() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    /// The next chunk of audio. Calls are meant to be made one after the other, not concurrently.
    func next() async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.produce()) }
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
                return .chunk(Chunk(buffer: buffer, fileDuration: fileDuration))
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
        downmix = ChannelDownmix(format: format)
        readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.blockFrames))

        if format.sampleRate != outputFormat.sampleRate {
            guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                             channels: 2, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: outputFormat) else {
                throw DecoderError("can't convert \(Int(format.sampleRate)) Hz to \(Int(outputFormat.sampleRate)) Hz")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converterSourceFormat = source
            self.converter = converter
        }

        // A position past the end plays the last frame, not nothing.
        let start = min(max(Int64((startSeconds * format.sampleRate).rounded()), 0), file.length - 1)
        if start > 0 { file.framePosition = start }
        opened = true
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
        let remaining = file.length - file.framePosition
        guard remaining > 0 else { return nil }

        do {
            try file.read(into: readBuffer, frameCount: AVAudioFrameCount(min(Int64(Self.blockFrames), remaining)))
        } catch {
            warning = "decoding stopped after \(file.framePosition) of \(file.length) frames: \(error.localizedDescription)"
            return nil
        }
        guard readBuffer.frameLength > 0 else {
            warning = "the file ends after \(file.framePosition) of \(file.length) frames"
            return nil
        }

        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readBuffer.frameLength)!
        downmix.apply(readBuffer, to: block)
        return block
    }
}
