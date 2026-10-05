// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("CodecLabel")
    struct CodecLabelTests {
        private func label(_ fixture: String) throws -> String {
            let url = try Fixtures.url(fixture)
            let file = try AVAudioFile(forReading: url)
            return CodecLabel.make(url: url, fileFormat: file.fileFormat)
        }

        @Test("lossless files: name, bit depth and sample rate")
        func lossless() throws {
            #expect(try label("formats/t.flac") == "FLAC 16/44.1")
            #expect(try label("playback/r96_24.flac") == "FLAC 24/96")
            #expect(try label("playback/r48.flac") == "FLAC 16/48")
            #expect(try label("playback/a_alac.m4a") == "ALAC 16/44.1")
            #expect(try label("playback/a.wav") == "WAV 16/44.1")
            #expect(try label("playback/a.aiff") == "AIFF 16/44.1")
            #expect(try label("playback/a.caf") == "CAF 16/44.1")
        }

        @Test("lossy files: name and bit rate, MP3 also CBR or VBR")
        func lossy() throws {
            let mp3 = try label("playback/lossy.mp3")
            #expect(mp3.hasPrefix("MP3 CBR ") && mp3.hasSuffix("k"), "\(mp3)")
            #expect(Int(mp3.dropFirst("MP3 CBR ".count).dropLast()).map { (100...140).contains($0) } == true, "\(mp3)")

            let vbr = try label("playback/lossy_vbr.mp3")
            #expect(vbr.hasPrefix("MP3 VBR ") && vbr.hasSuffix("k"), "\(vbr)")

            let aac = try label("playback/lossy.m4a")
            #expect(aac.hasPrefix("AAC "), "\(aac)")
            #expect(aac.hasSuffix("k") && Int(aac.dropFirst("AAC ".count).dropLast()) != nil, "\(aac)")

            let ogg = try label("playback/lossy.ogg")
            #expect(ogg.hasPrefix("OGG "), "\(ogg)")
            #expect(ogg.hasSuffix("k") && Int(ogg.dropFirst("OGG ".count).dropLast()) != nil, "\(ogg)")
        }
    }
}
