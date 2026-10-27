// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation

/// A file macOS opens by itself, read through `AVAudioFile`: its length is the exact number of audio frames, and it
/// lands on the frame it is asked to in every format (except for the history Opus needs, see `SeekPreroll`).
final class AVAudioFileSource: PCMSource {
    private let url: URL
    private let file: AVAudioFile
    /// For the pre-roll of a seek; made when one is needed.
    private var scratch: AVAudioPCMBuffer?

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forReading: url)
        length = file.length
    }

    let length: Int64
    var processingFormat: AVAudioFormat { file.processingFormat }
    var framePosition: Int64 { file.framePosition }
    var codec: String { CodecLabel.make(url: url, fileFormat: file.fileFormat) }

    func seek(to frame: Int64) throws {
        // `framePosition` raises an Objective-C exception outside 0..<length.
        guard frame >= 0, frame < length else { throw PCMSourceError("can't seek to frame \(frame) of \(length)") }
        let preroll = min(frame, SeekPreroll.frames(for: file))
        guard preroll > 0 else {
            file.framePosition = frame
            return
        }

        if scratch == nil {
            scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
        }
        file.framePosition = frame - preroll
        // If the pre-roll can't be read (a damaged file) the file is positioned at `frame` anyway, as a plain seek would.
        if let scratch {
            var remaining = preroll
            while remaining > 0 {
                do {
                    try file.read(into: scratch, frameCount: AVAudioFrameCount(min(Int64(scratch.frameCapacity), remaining)))
                } catch {
                    break
                }
                guard scratch.frameLength > 0 else { break }
                remaining -= Int64(scratch.frameLength)
            }
        }
        if file.framePosition != frame { file.framePosition = frame }
    }

    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        // A read that reaches past the end fails in some formats (FLAC), instead of coming back short.
        let remaining = length - file.framePosition
        guard remaining > 0 else {
            buffer.frameLength = 0
            return
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(frameCount), remaining)))
    }
}
