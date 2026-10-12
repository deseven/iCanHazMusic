// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import SwiftUI

/// What is expensive to make from a waveform and doesn't change while it plays: the spectrogram as an image. Remembers
/// the last one.
final class WaveformArtwork {
    private var waveform: Waveform?
    private var columns = 0
    private var image: CGImage?

    /// An alpha-only looking RGBA image (white, premultiplied: the colour channels equal the alpha) of `columns` x
    /// `Waveform.bandCount` pixels, highest band at the top, to be drawn as a template in the accent colour.
    func spectrogram(of waveform: Waveform, columns: Int) -> CGImage? {
        if self.waveform == waveform, self.columns == columns { return image }
        let cells = waveform.spectrogram(columns: columns)
        let rows = Waveform.bandCount
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        for x in 0..<columns {
            for band in 0..<rows {
                let intensity = Double(cells[x * rows + band]) / 255
                // A faint floor keeps the whole strip visible, so quiet passages don't look like holes.
                let alpha = UInt8(((WaveformBars.spectrogramFloor + (1 - WaveformBars.spectrogramFloor) * intensity) * 255).rounded())
                let offset = ((rows - 1 - band) * columns + x) * 4
                pixels[offset] = alpha
                pixels[offset + 1] = alpha
                pixels[offset + 2] = alpha
                pixels[offset + 3] = alpha
            }
        }
        var made: CGImage?
        pixels.withUnsafeMutableBytes { raw in
            if let context = CGContext(data: raw.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                       bytesPerRow: columns * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                made = context.makeImage()
            }
        }
        self.waveform = waveform
        self.columns = columns
        image = made
        return made
    }
}

/// The drawing of the visual seek bars (see `WaveformSeekBar`): the whole bar either as played or as not played yet, no
/// position line. It is only drawn into an image once per waveform/size/appearance (`WaveformImages`); the seek bar
/// then shows the played image left of the position and the other one right of it.
struct WaveformBars: View {
    let style: SeekbarStyle
    let waveform: Waveform?
    let artwork: WaveformArtwork
    /// Every bar as played (full opacity) or as not played yet (its share of it).
    let played: Bool
    let accent: Color
    /// The text colour, which stands out of the accent colour in either appearance (the structure ticks).
    let primary: Color

    // Starting values, to be tuned by eye on real tracks.
    /// Width of a bar plus the gap after it, at most; the bars share the width evenly.
    private static let slotWidth: CGFloat = 1.5
    /// The share of a slot a bar fills.
    private static let barShare: CGFloat = 2.0 / 3.0
    /// So silence reads as a dotted line, not as a hole.
    static let minBarHeight: CGFloat = 2
    /// Columns more than this many dB below the loudest one have no bar (just the minimum height).
    private static let rangeDB = 48.0
    /// Height = (amplitude relative to the loudest column)^exponent: 1 is linear (most contrast), lower flattens it.
    /// A dB-linear height made even 12 dB quieter passages 70% tall; at 0.6 they are ~43% (6 dB: 66%, 20 dB: 25%).
    private static let heightExponent = 0.6
    /// Peak + RMS: both layers are linear amplitude relative to the track's largest peak, which is how the two relate.
    private static let peakExponent = 1.0
    /// Tri-band: height of a layer relative to the loudest column's total.
    private static let triBandExponent = 0.6
    /// Opacity of the bars not played yet, as a share of what they have when played.
    private static let unplayedShare = 0.5
    /// Opacity of a bar of the RMS and structure styles when played.
    private static let playedOpacity = 1.0
    /// The same while there is no waveform (the dotted line).
    private static let placeholderUnplayedOpacity = 0.25
    private static let placeholderPlayedOpacity = 0.5
    /// Peak + RMS: opacity of the peak layer when played (the RMS layer is `playedOpacity`).
    private static let peakLayerOpacity = 0.35
    /// Tri-band: opacities of the layers when played; drawn over each other, so they add up (0.30, 0.55, 0.78).
    private static let triBandOpacities = (all: 0.30, upper: 0.35, high: 0.50)
    /// Spectrogram: opacity of the quietest cell.
    static let spectrogramFloor = 0.06
    /// Structure: ticks where the sections change.
    private static let tickWidth: CGFloat = 1.5
    private static let tickHeight: CGFloat = 4
    private static let tickOpacity = 0.7
    /// Structure: the colour of a section is `palette[label % palette.count]` (system colours: they follow the
    /// appearance); sections that sound alike have the same label.
    private static let palette: [Color] = [.red, .blue, .yellow, .green, .purple, .pink, .teal, .orange, .indigo, .mint,
                                           .cyan, .brown]

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            if let waveform, style == .spectrogram {
                drawSpectrogram(waveform, in: &context, size: size)
            } else {
                drawBars(in: &context, size: size)
            }
        }
    }

    // MARK: Bars

    private struct Geometry {
        let size: CGSize
        let count: Int
        let slot: CGFloat
        let barWidth: CGFloat

        func rect(_ index: Int, height: CGFloat) -> CGRect {
            CGRect(x: CGFloat(index) * slot + (slot - barWidth) / 2, y: (size.height - height) / 2,
                   width: barWidth, height: height)
        }
    }

    private func geometry(_ size: CGSize) -> Geometry {
        let count = max(1, Int(size.width / Self.slotWidth))
        let slot = size.width / CGFloat(count)
        return Geometry(size: size, count: count, slot: slot, barWidth: slot * Self.barShare)
    }

    /// One bar: `height` is clamped up to the minimum; `opacity` is the played one, the unplayed ones get their share.
    private func fillBar(_ context: inout GraphicsContext, _ g: Geometry, _ index: Int, height: CGFloat,
                         color: Color, opacity: Double) {
        let shown = max(Self.minBarHeight, height)
        let rect = g.rect(index, height: shown)
        let alpha = played ? opacity : opacity * Self.unplayedShare
        context.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, shown) / 2), with: .color(color.opacity(alpha)))
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let g = geometry(size)

        guard let waveform else {
            // The dotted line: played ones a little brighter, like the real bars.
            let alpha = played ? Self.placeholderPlayedOpacity : Self.placeholderUnplayedOpacity
            for i in 0..<g.count {
                let rect = g.rect(i, height: Self.minBarHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(accent.opacity(alpha)))
            }
            return
        }

        switch style {
        case .standard, .waveformRMS, .spectrogram:
            let heights = waveform.bars(g.count, rangeDB: Self.rangeDB, exponent: Self.heightExponent)
            for i in 0..<g.count {
                fillBar(&context, g, i, height: CGFloat(heights[i]) * size.height, color: accent, opacity: Self.playedOpacity)
            }

        case .waveformPeakRMS:
            let layers = waveform.peakBars(g.count, exponent: Self.peakExponent)
            for i in 0..<g.count {
                fillBar(&context, g, i, height: CGFloat(layers.peak[i]) * size.height, color: accent,
                        opacity: Self.peakLayerOpacity)
                fillBar(&context, g, i, height: CGFloat(layers.rms[i]) * size.height, color: accent,
                        opacity: Self.playedOpacity)
            }

        case .waveformTriBand:
            let layers = waveform.triBandBars(g.count, exponent: Self.triBandExponent)
            for i in 0..<g.count {
                fillBar(&context, g, i, height: CGFloat(layers.all[i]) * size.height, color: accent,
                        opacity: Self.triBandOpacities.all)
                // The inner layers have no minimum: where they are empty there is nothing to show.
                let upper = CGFloat(layers.upper[i]) * size.height
                if upper > Self.minBarHeight {
                    fillBar(&context, g, i, height: upper, color: accent, opacity: Self.triBandOpacities.upper)
                }
                let high = CGFloat(layers.high[i]) * size.height
                if high > Self.minBarHeight {
                    fillBar(&context, g, i, height: high, color: accent, opacity: Self.triBandOpacities.high)
                }
            }

        case .waveformStructure:
            let heights = waveform.bars(g.count, rangeDB: Self.rangeDB, exponent: Self.heightExponent)
            let labels = waveform.segmentLabels(g.count)
            for i in 0..<g.count {
                fillBar(&context, g, i, height: CGFloat(heights[i]) * size.height,
                        color: Self.palette[labels[i] % Self.palette.count], opacity: Self.playedOpacity)
            }
            let tick = primary.opacity(Self.tickOpacity)
            for boundary in waveform.boundaryFractions {
                let x = min(max(size.width * CGFloat(boundary), Self.tickWidth / 2), size.width - Self.tickWidth / 2)
                for y in [0, size.height - Self.tickHeight] {
                    context.fill(Path(CGRect(x: x - Self.tickWidth / 2, y: y, width: Self.tickWidth, height: Self.tickHeight)),
                                 with: .color(tick))
                }
            }
        }
    }

    // MARK: Spectrogram

    private func drawSpectrogram(_ waveform: Waveform, in context: inout GraphicsContext, size: CGSize) {
        let columns = max(1, Int(size.width))
        guard let cgImage = artwork.spectrogram(of: waveform, columns: columns) else { return }
        var resolved = context.resolve(Image(decorative: cgImage, scale: 1).interpolation(.high))
        resolved.shading = .color(accent)
        context.opacity = Self.playedOpacity * (played ? 1 : Self.unplayedShare)
        context.draw(resolved, in: CGRect(origin: .zero, size: size))
    }
}

/// The two images the seek bar is made of: the whole bar as played and as not played yet.
@MainActor
enum WaveformImages {
    struct Request: Equatable {
        let style: SeekbarStyle
        let waveform: Waveform?
        let size: CGSize
        /// Pixels per point.
        let scale: CGFloat
        let colorScheme: ColorScheme
        let accent: Color.Resolved
        let primary: Color.Resolved
    }

    /// nil if the size is empty or the renderer gives nothing.
    static func render(_ request: Request, artwork: WaveformArtwork) -> (played: CGImage, unplayed: CGImage)? {
        guard request.size.width >= 1, request.size.height >= 1 else { return nil }
        func image(played: Bool) -> CGImage? {
            let content = WaveformBars(style: request.style, waveform: request.waveform, artwork: artwork,
                                       played: played, accent: Color(request.accent), primary: Color(request.primary))
                .frame(width: request.size.width, height: request.size.height)
                .environment(\.colorScheme, request.colorScheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = request.scale
            return renderer.cgImage
        }
        guard let played = image(played: true), let unplayed = image(played: false) else { return nil }
        return (played, unplayed)
    }
}
