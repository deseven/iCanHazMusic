// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AudioToolbox
import AVFoundation
import Foundation

/// The short description of a file's format shown next to a track, e.g. "MP3 CBR 320k", "AAC 256k", "OGG 128k",
/// "FLAC 24/96", "WAV 16/44.1".
///
/// - Lossy formats: the name and the average bit rate in kbit/s. For MP3 also whether the packets all have the
///   same size (CBR) or not (VBR).
/// - Lossless formats: the name, the bit depth and the sample rate in kHz (the bit rate of lossless audio says little).
///
/// Everything comes from the file's own stream description and from AudioToolbox's file properties, which are
/// cheap (they don't decode anything). Whatever is unknown is left out, down to the bare file extension.
enum CodecLabel {
    static func make(url: URL, fileFormat: AVAudioFormat) -> String {
        let asbd = fileFormat.streamDescription.pointee
        let ext = url.pathExtension.uppercased()
        let probe = Probe(url: url)

        switch asbd.mFormatID {
        case kAudioFormatMPEGLayer3:
            return join("MP3", probe.isVariableBitRate.map { $0 ? "VBR" : "CBR" }, kbps(probe.bitRate))
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR, kAudioFormatMPEG4AAC_ELD_V2,
             kAudioFormatMPEG4AAC_Spatial:
            return join("AAC", kbps(probe.bitRate))
        case kAudioFormatFLAC:
            return join("FLAC", lossless(depth: probe.bitDepth.map { "\($0)" }, rate: asbd.mSampleRate))
        case kAudioFormatAppleLossless:
            return join("ALAC", lossless(depth: probe.bitDepth.map { "\($0)" }, rate: asbd.mSampleRate))
        case kAudioFormatLinearPCM:
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let depth = asbd.mBitsPerChannel > 0 ? "\(asbd.mBitsPerChannel)" + (isFloat ? "f" : "") : nil
            return join(ext, lossless(depth: depth, rate: asbd.mSampleRate))
        case Self.vorbis:
            return join("OGG", kbps(probe.bitRate))
        default:
            return join(ext, kbps(probe.bitRate))
        }
    }

    /// `kAudioFormatXiphVorbis`, which the SDK headers don't export under that name.
    private static let vorbis: AudioFormatID = 0x766F7262   // 'vorb'

    // MARK: Formatting

    private static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func kbps(_ bitsPerSecond: Double?) -> String? {
        guard let bitsPerSecond, bitsPerSecond >= 500 else { return nil }
        return "\(Int((bitsPerSecond / 1000).rounded()))k"
    }

    /// "24/96", "16/44.1"; just the rate if the depth isn't known.
    private static func lossless(depth: String?, rate: Double) -> String? {
        guard rate > 0 else { return depth }
        let khz = String(format: "%g", (rate / 1000 * 10).rounded() / 10)
        return depth.map { "\($0)/\(khz)" } ?? khz
    }

    // MARK: AudioToolbox

    /// What `AudioFile` knows about the file.
    private struct Probe {
        private(set) var bitRate: Double?
        /// MP3 only: the largest packet is clearly larger than the average one.
        private(set) var isVariableBitRate: Bool?
        /// FLAC and ALAC: bit depth, from the format flags (1: 16, 2: 20, 3: 24, 4: 32 bit source).
        private(set) var bitDepth: Int?

        init(url: URL) {
            var opened: AudioFileID?
            guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &opened) == noErr, let file = opened else { return }
            defer { AudioFileClose(file) }

            func value<T>(_ property: AudioFilePropertyID, _ initial: T) -> T? {
                var result = initial
                var size = UInt32(MemoryLayout<T>.size)
                let status = withUnsafeMutablePointer(to: &result) { AudioFileGetProperty(file, property, &size, $0) }
                return status == noErr ? result : nil
            }

            if let bits: UInt32 = value(kAudioFilePropertyBitRate, 0), bits > 0 { bitRate = Double(bits) }

            if let format: AudioStreamBasicDescription = value(kAudioFilePropertyDataFormat, AudioStreamBasicDescription()) {
                switch format.mFormatFlags {
                case 1: bitDepth = 16
                case 2: bitDepth = 20
                case 3: bitDepth = 24
                case 4: bitDepth = 32
                default: break
                }
                if format.mFormatID == kAudioFormatMPEGLayer3,
                   let bytes: UInt64 = value(kAudioFilePropertyAudioDataByteCount, 0),
                   let packets: UInt64 = value(kAudioFilePropertyAudioDataPacketCount, 0),
                   let largest: UInt32 = value(kAudioFilePropertyMaximumPacketSize, 0), packets > 0 {
                    // A CBR stream only differs by the padding byte; leave some room for the odd frame.
                    isVariableBitRate = Double(largest) > Double(bytes) / Double(packets) * 1.03 + 2
                }
            }
        }
    }
}
