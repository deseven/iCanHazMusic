// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AudioToolbox
import AVFoundation
import Foundation

/// The `processingFormat` of the sources that decode a file by themselves: float 32, non-interleaved, and for more than
/// two channels with a layout that says which channel is which (what `ChannelDownmix` goes by).
///
/// Files of these formats describe their layout the way WAV files do, with a bit mask of speaker positions
/// (`WAVEFORMATEXTENSIBLE.dwChannelMask`); the channels are in the order of the bits.
enum SourceFormat {
    /// More channels than this are not a file the app can play.
    static let maxChannels = 32

    /// `waveMask` 0: the file doesn't say, so channels 3 to 8 are taken to be what a WAV file of that many channels has.
    static func make(sampleRate: Double, channels: Int, waveMask: UInt32) -> AVAudioFormat? {
        guard channels >= 1, channels <= maxChannels, sampleRate > 0 else { return nil }
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                 channels: AVAudioChannelCount(channels), interleaved: false)
        }
        let layout = labels(waveMask: waveMask, channels: channels).flatMap(channelLayout)
            ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
        guard let layout else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false,
                             channelLayout: layout)
    }

    /// The channel labels of a speaker mask in channel order, `nil` if it doesn't describe `channels` channels.
    static func labels(waveMask: UInt32, channels: Int) -> [AudioChannelLabel]? {
        var mask = waveMask
        if mask == 0 || mask.nonzeroBitCount != channels { mask = defaultMask(channels: channels) }
        guard mask.nonzeroBitCount == channels else { return nil }
        var labels: [AudioChannelLabel] = []
        for (bit, label) in speakers.enumerated() where mask & (1 << UInt32(bit)) != 0 { labels.append(label) }
        // A mask with bits beyond the known positions.
        return labels.count == channels ? labels : nil
    }

    /// The positions of a WAV file of `channels` channels that says nothing: 3 front, quad, 5.0, 5.1, 6.1, 7.1.
    private static func defaultMask(channels: Int) -> UInt32 {
        switch channels {
        case 3: 0x7
        case 4: 0x33
        case 5: 0x37
        case 6: 0x3F
        case 7: 0x70F
        case 8: 0x63F
        default: 0
        }
    }

    /// The speaker positions of a WAV file, bit by bit.
    private static let speakers: [AudioChannelLabel] = [
        kAudioChannelLabel_Left,                    // front left
        kAudioChannelLabel_Right,                   // front right
        kAudioChannelLabel_Center,                  // front centre
        kAudioChannelLabel_LFEScreen,               // low frequency
        kAudioChannelLabel_RearSurroundLeft,        // back left
        kAudioChannelLabel_RearSurroundRight,       // back right
        kAudioChannelLabel_LeftCenter,              // front left of centre
        kAudioChannelLabel_RightCenter,             // front right of centre
        kAudioChannelLabel_CenterSurround,          // back centre
        kAudioChannelLabel_LeftSurroundDirect,      // side left
        kAudioChannelLabel_RightSurroundDirect,     // side right
        kAudioChannelLabel_TopCenterSurround,       // top centre
        kAudioChannelLabel_VerticalHeightLeft,      // top front left
        kAudioChannelLabel_VerticalHeightCenter,    // top front centre
        kAudioChannelLabel_VerticalHeightRight,     // top front right
        kAudioChannelLabel_TopBackLeft,             // top back left
        kAudioChannelLabel_TopBackCenter,           // top back centre
        kAudioChannelLabel_TopBackRight,            // top back right
    ]

    private static func channelLayout(labels: [AudioChannelLabel]) -> AVAudioChannelLayout? {
        guard let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return nil }
        let size = offset + labels.count * MemoryLayout<AudioChannelDescription>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)

        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        let descriptions = (raw + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        for (i, label) in labels.enumerated() {
            descriptions[i] = AudioChannelDescription(mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0))
        }
        return AVAudioChannelLayout(layout: layout)
    }
}
