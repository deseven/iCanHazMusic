// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// The two images the visual seek bars are made of (`WaveformImages`).
    @MainActor @Suite("WaveformImages")
    struct WaveformImagesTests {
        private func request(_ style: SeekbarStyle, waveform: Waveform?) -> WaveformImages.Request {
            let environment = EnvironmentValues()
            return WaveformImages.Request(style: style, waveform: waveform, size: CGSize(width: 120, height: 50), scale: 2,
                                          colorScheme: .light, accent: Color.blue.resolve(in: environment),
                                          primary: Color.black.resolve(in: environment))
        }

        private func waveform() -> Waveform {
            let rms = (0..<Waveform.bucketCount).map { UInt8(40 + ($0 % 200) / 2) }
            return Waveform(rms: rms, peak: rms.map { min($0 &+ 20, 255) },
                            bands: [UInt8](repeating: 120, count: Waveform.bucketCount * Waveform.bandCount))
        }

        /// The highest alpha value and the number of pixels that aren't transparent.
        private func alpha(of image: CGImage) -> (max: UInt8, visible: Int) {
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return (0, 0) }
            var highest: UInt8 = 0
            var visible = 0
            for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] > 0 {
                visible += 1
                highest = max(highest, pixels[i])
            }
            return (highest, visible)
        }

        @Test("every style makes a played and a fainter not played image, in pixels of the size asked for")
        func rendersAllStyles() throws {
            for style in SeekbarStyle.allCases where style != .standard {
                let images = try #require(WaveformImages.render(request(style, waveform: waveform()), artwork: WaveformArtwork()),
                                          "\(style)")
                #expect(images.played.width == 240 && images.played.height == 100, "\(style)")
                #expect(images.unplayed.width == 240 && images.unplayed.height == 100, "\(style)")
                let played = alpha(of: images.played)
                let unplayed = alpha(of: images.unplayed)
                #expect(played.visible > 0 && unplayed.visible > 0, "\(style): something is drawn")
                #expect(played.max > unplayed.max, "\(style): played is stronger (\(played.max) vs \(unplayed.max))")
            }
        }

        @Test("without a waveform there is a dotted line")
        func placeholder() throws {
            let images = try #require(WaveformImages.render(request(.waveformRMS, waveform: nil), artwork: WaveformArtwork()))
            let played = alpha(of: images.played)
            #expect(played.visible > 0)
            // Only the dotted line at the minimum height, not the whole bar.
            #expect(played.visible < 240 * 100 / 10)
        }

        @Test("nothing is made for an empty size")
        func emptySize() {
            var empty = request(.waveformRMS, waveform: nil)
            empty = WaveformImages.Request(style: empty.style, waveform: nil, size: .zero, scale: 2,
                                           colorScheme: .light, accent: empty.accent, primary: empty.primary)
            #expect(WaveformImages.render(empty, artwork: WaveformArtwork()) == nil)
        }
    }
}
