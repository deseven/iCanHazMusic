// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation

/// What `TrackDecoder` and `WaveformAnalyzer` read an audio file through: its frames as 32 bit float PCM, counted exactly,
/// and nothing about how they are stored.
///
/// Three implementations, picked by `PCMSources.open` from the file's extension:
/// - `AVAudioFileSource`: everything macOS opens (MP3, AAC, FLAC, ALAC, Vorbis, Opus, WAV, AIFF, CAF).
/// - `WavPackSource` and `APESource`: the two formats macOS can't open at all, decoded by the libraries in `vendor/`.
///
/// A source is not thread safe: one thread at a time. Everything it does can block on the file (a network share that
/// went away), so it is used from a queue of its own, see `TrackDecoder`.
protocol PCMSource: AnyObject {
    /// The number of audio frames of the file, exactly (no padding of the last packet).
    var length: Int64 { get }

    /// Float 32, non-interleaved, at the file's own sample rate. A file of more than two channels has the layout of
    /// its channels in it, which is what `ChannelDownmix` mixes by.
    var processingFormat: AVAudioFormat { get }

    /// The frame the next `read` starts at.
    var framePosition: Int64 { get }

    /// The format description for `CodecLabel` ("FLAC 24/96", "WV 16/44.1"). Everything it needs is in the file's
    /// header; it can still take a moment, so ask once.
    var codec: String { get }

    /// Positions the source at `frame` (which must lie in `0..<length`) so that the next read delivers the audio of
    /// exactly that frame, fully decoded: formats whose decoder needs history first decode a little before the target
    /// (`SeekPreroll`). Throws if the file can't be positioned (a damaged one).
    func seek(to frame: Int64) throws

    /// Reads the next `frameCount` frames (at most `buffer.frameCapacity`) into `buffer` and sets its `frameLength`:
    /// fewer where the file ends, 0 at the end. Throws if the file can't be decoded.
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws
}

/// The formats that macOS can't open, and the app plays with decoders of its own (`vendor/README.md`).
enum ExtraFormat: Sendable {
    case wavPack
    case ape

    /// By the file extension (compared case-insensitively); `nil` for everything else.
    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "wv": self = .wavPack
        case "ape": self = .ape
        default: return nil
        }
    }
}

enum PCMSources {
    /// Opens `url` for decoding. Blocks as long as the file does.
    static func open(url: URL) throws -> PCMSource {
        switch ExtraFormat(url: url) {
        case .wavPack?: try WavPackSource(url: url)
        case .ape?: try APESource(url: url)
        case nil: try AVAudioFileSource(url: url)
        }
    }
}

/// What the sources of the extra formats throw: a message for the log and the playlist.
struct PCMSourceError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
