// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import AudioToolbox

/// Folds the channels of a file down to stereo, the one layout the playback engine works with.
///
/// - Stereo is copied untouched (bit for bit), mono goes to both sides at unity gain.
/// - Anything else is mixed with the usual ITU-style coefficients, picked by the channel *labels* of the file's
///   layout: centre and the surround/height channels at -3 dB into the matching side, the LFE dropped. The sums
///   are normalised so that all channels at full scale can't clip.
/// - A file without a usable layout is spread over left and right in turn (also normalised).
///
/// `AVAudioMixerNode` isn't used for this: it plays mono 3 dB too quiet, lets 5.1 clip and `AVAudioConverter`
/// silently drops the centre and surround channels.
struct ChannelDownmix: Equatable {
    struct Coefficients: Equatable {
        var left: Float
        var right: Float
    }

    /// Per source channel: how much of it goes to the left and to the right output.
    let coefficients: [Coefficients]

    /// Stereo in, stereo out: the samples are just copied.
    var isStereoCopy: Bool {
        coefficients == [Coefficients(left: 1, right: 0), Coefficients(left: 0, right: 1)]
    }

    private static let minusThreeDB: Float = 0.70710678

    init(channelCount: Int, labels: [AudioChannelLabel]? = nil) {
        precondition(channelCount > 0, "no channels")
        var raw: [Coefficients]
        switch channelCount {
        case 1:
            raw = [Coefficients(left: 1, right: 1)]
        case 2:
            raw = [Coefficients(left: 1, right: 0), Coefficients(left: 0, right: 1)]
        default:
            if let labels, labels.count == channelCount {
                raw = labels.enumerated().map { Self.coefficients(for: $1, index: $0) }
            } else {
                raw = (0..<channelCount).map { Self.alternating(index: $0) }
            }
        }

        // Normalise so that the loudest possible sum is 1.
        let gain = 1 / max(1, raw.reduce(0) { $0 + $1.left }, raw.reduce(0) { $0 + $1.right })
        if gain < 1 {
            raw = raw.map { Coefficients(left: $0.left * gain, right: $0.right * gain) }
        }
        coefficients = raw
    }

    init(format: AVAudioFormat) {
        self.init(channelCount: Int(format.channelCount), labels: Self.labels(of: format))
    }

    // MARK: Mixing

    /// Writes the stereo mix of `source` to `destination` (two channels, capacity for at least as many frames)
    /// and sets its `frameLength`.
    func apply(_ source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
        let frames = Int(source.frameLength)
        precondition(Int(source.format.channelCount) == coefficients.count, "channel count mismatch")
        precondition(destination.format.channelCount == 2 && Int(destination.frameCapacity) >= frames)
        destination.frameLength = AVAudioFrameCount(frames)
        guard frames > 0, let src = source.floatChannelData, let dst = destination.floatChannelData else { return }

        if isStereoCopy {
            dst[0].update(from: src[0], count: frames)
            dst[1].update(from: src[1], count: frames)
            return
        }

        dst[0].update(repeating: 0, count: frames)
        dst[1].update(repeating: 0, count: frames)
        for (channel, c) in coefficients.enumerated() where c.left != 0 || c.right != 0 {
            let s = src[channel]
            if c.left != 0 { for i in 0..<frames { dst[0][i] += s[i] * c.left } }
            if c.right != 0 { for i in 0..<frames { dst[1][i] += s[i] * c.right } }
        }
    }

    // MARK: Layout

    private static func coefficients(for label: AudioChannelLabel, index: Int) -> Coefficients {
        let h = minusThreeDB
        switch label {
        case kAudioChannelLabel_Left, kAudioChannelLabel_LeftTotal, kAudioChannelLabel_LeftWide:
            return Coefficients(left: 1, right: 0)
        case kAudioChannelLabel_Right, kAudioChannelLabel_RightTotal, kAudioChannelLabel_RightWide:
            return Coefficients(left: 0, right: 1)
        case kAudioChannelLabel_Center, kAudioChannelLabel_Mono:
            return Coefficients(left: h, right: h)
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect,
             kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftCenter,
             kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_TopBackLeft:
            return Coefficients(left: h, right: 0)
        case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect,
             kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightCenter,
             kAudioChannelLabel_VerticalHeightRight, kAudioChannelLabel_TopBackRight:
            return Coefficients(left: 0, right: h)
        case kAudioChannelLabel_CenterSurround, kAudioChannelLabel_TopCenterSurround,
             kAudioChannelLabel_VerticalHeightCenter, kAudioChannelLabel_TopBackCenter:
            return Coefficients(left: 0.5, right: 0.5)
        case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2:
            return Coefficients(left: 0, right: 0)
        default:
            return alternating(index: index)
        }
    }

    /// Unknown channels: even ones to the left, odd ones to the right.
    private static func alternating(index: Int) -> Coefficients {
        index % 2 == 0 ? Coefficients(left: minusThreeDB, right: 0) : Coefficients(left: 0, right: minusThreeDB)
    }

    /// The channel labels of the format's layout, in channel order; `nil` if it has none that can be resolved.
    static func labels(of format: AVAudioFormat) -> [AudioChannelLabel]? {
        guard let layout = format.channelLayout?.layout else { return nil }
        let count = Int(format.channelCount)
        let tag = layout.pointee.mChannelLayoutTag

        let labels: [AudioChannelLabel]?
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            labels = descriptionLabels(of: layout)
        } else if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            labels = nil
        } else {
            var tagValue = tag
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,
                                             UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tagValue, &size) == noErr,
                  size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,
                                         UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tagValue, &size, raw) == noErr else { return nil }
            labels = descriptionLabels(of: UnsafePointer(raw.assumingMemoryBound(to: AudioChannelLayout.self)))
        }
        guard let labels, labels.count == count else { return nil }
        return labels
    }

    /// Reads the (variable length) channel description array that follows an `AudioChannelLayout` header.
    private static func descriptionLabels(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        guard count > 0, let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return [] }
        let base = UnsafeRawPointer(layout) + offset
        let stride = MemoryLayout<AudioChannelDescription>.stride
        return (0..<count).map {
            base.loadUnaligned(fromByteOffset: $0 * stride, as: AudioChannelDescription.self).mChannelLabel
        }
    }
}
