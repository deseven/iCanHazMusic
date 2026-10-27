// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation

/// How much audio before a seek target has to be decoded (and dropped) for the audio at the target to come out right.
///
/// `AVAudioFile` lands on the requested frame in every format, but for **Opus** it starts the decoder there without any
/// history, and an Opus decoder needs some: the first ~150 ms after a plain seek come out faded in and distorted (error
/// -2 dB at the target, still -20 dB 80 ms later). Measured against `opusdec` (frequency sweep, macOS 26): 80 ms of
/// pre-roll (what libopus suggests) still leaves -21 dB, 250 ms -71 dB, 400 ms nothing measurable. Every other format
/// needs none (sample-exact, see `dev-docs/playback.md`), and neither do WavPack and APE, whose decoders seek
/// sample-exactly by themselves. `AVAudioFileSource.seek` does the pre-roll.
enum SeekPreroll {
    /// Pre-roll for Opus, with some margin over the 400 ms measured.
    static let opusSeconds = 0.5

    /// Frames of `file` (at its processing rate) to decode before a seek target.
    static func frames(for file: AVAudioFile) -> Int64 {
        guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatOpus else { return 0 }
        return Int64((opusSeconds * file.processingFormat.sampleRate).rounded())
    }
}
