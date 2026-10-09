// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import SwiftUI

/// The visual seek bar styles (everything of `SeekbarStyle` but the default one): the track over time, drawn from the
/// data of `Waveform`, in the accent colour on a transparent background. What is not played yet is half-transparent;
/// the played part is drawn at full opacity, so it "lights up" as the track plays. The current position is a thicker line.
/// Click/drag seeks like the default bar (`seekGesture`).
///
/// - `waveformRMS`: mirrored, rounded bars of the loudness.
/// - `waveformPeakRMS`: the peaks as a faint layer, the RMS in front of it.
/// - `waveformTriBand`: three nested layers (all frequencies, mid + high, high) in increasing opacity of the one colour.
/// - `waveformStructure`: the RMS bars in the colour of the section of the track they belong to (sections that sound
///   alike share a colour), ticks at the top and bottom where the sections change.
/// - `spectrogram`: frequency (low at the bottom) over time, the intensity as opacity.
///
/// While the waveform isn't there (being made, or the track can't be analysed) the bars are a dimmed dotted line at
/// minimum height; the played bars and the line work as usual, so the bar is usable from the first frame.
struct WaveformSeekBar: View {
    let style: SeekbarStyle
    let value: Double
    let total: Double
    /// The position being dragged to, nil when not dragging.
    @Binding var scrubbing: Double?
    let onSeek: (Double) -> Void

    private let service = WaveformService.shared
    @State private var artwork = WaveformArtwork()

    var body: some View {
        // Read here, not inside the GeometryReader, so the view is redrawn when the waveform arrives.
        let waveform = service.current
        GeometryReader { geo in
            let shown = scrubbing ?? value
            let fraction = total > 0 ? min(max(shown / total, 0), 1) : 0
            WaveformBars(style: style, waveform: waveform, artwork: artwork, fraction: fraction,
                         grow: waveform == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.3), value: waveform != nil)
                .frame(width: geo.size.width, height: geo.size.height)
                .seekGesture(width: geo.size.width, total: total, scrubbing: $scrubbing, onSeek: onSeek)
        }
        .frame(height: Layout.waveformSeekbarHeight)
    }
}

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

/// The drawing. Animatable in `grow` (0 = every bar at minimum height / the spectrogram invisible, 1 = all there), so
/// the bars rise when the waveform arrives.
private struct WaveformBars: View, Animatable {
    let style: SeekbarStyle
    let waveform: Waveform?
    let artwork: WaveformArtwork
    /// How much of the track is played, 0...1.
    let fraction: Double
    var grow: Double

    var animatableData: Double {
        get { grow }
        set { grow = newValue }
    }

    // Starting values, to be tuned by eye on real tracks.
    /// Width of a bar plus the gap after it, at most; the bars share the width evenly.
    private static let slotWidth: CGFloat = 1.5
    /// The share of a slot a bar fills.
    private static let barShare: CGFloat = 2.0 / 3.0
    /// So silence reads as a dotted line, not as a hole.
    private static let minBarHeight: CGFloat = 2
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
    private static let positionLineWidth: CGFloat = 2.5
    /// How much black is mixed into the accent colour for the position line.
    private static let positionLineDarkening = 0.45
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
            let playedColor: Color
            if let waveform, style == .spectrogram {
                drawSpectrogram(waveform, in: &context, size: size)
                playedColor = .primary
            } else {
                drawBars(in: &context, size: size)
                playedColor = Color.accentColor.mix(with: .black, by: Self.positionLineDarkening)
            }

            // The current position, kept inside the frame at the ends so it isn't cut off.
            let x = size.width * CGFloat(fraction)
            let half = Self.positionLineWidth / 2
            let center = min(max(x, half), size.width - half)
            context.fill(Path(CGRect(x: center - half, y: 0, width: Self.positionLineWidth, height: size.height)),
                         with: .color(playedColor))
        }
    }

    // MARK: Bars

    private struct Geometry {
        let size: CGSize
        let count: Int
        let slot: CGFloat
        let barWidth: CGFloat
        let playedCount: Int

        func rect(_ index: Int, height: CGFloat) -> CGRect {
            CGRect(x: CGFloat(index) * slot + (slot - barWidth) / 2, y: (size.height - height) / 2,
                   width: barWidth, height: height)
        }
    }

    private func geometry(_ size: CGSize) -> Geometry {
        let count = max(1, Int(size.width / Self.slotWidth))
        let slot = size.width / CGFloat(count)
        return Geometry(size: size, count: count, slot: slot, barWidth: slot * Self.barShare,
                        playedCount: Int((fraction * Double(count)).rounded()))
    }

    /// One bar: `height` is clamped up to the minimum; `opacity` is the played one, the unplayed ones get their share.
    private func fillBar(_ context: inout GraphicsContext, _ g: Geometry, _ index: Int, height: CGFloat,
                         color: Color, opacity: Double) {
        let shown = max(Self.minBarHeight, height)
        let rect = g.rect(index, height: shown)
        let alpha = index < g.playedCount ? opacity : opacity * Self.unplayedShare
        context.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, shown) / 2), with: .color(color.opacity(alpha)))
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let g = geometry(size)
        let accent = Color.accentColor
        let grow = CGFloat(grow)

        guard let waveform else {
            // The dotted line: played ones a little brighter, like the real bars.
            for i in 0..<g.count {
                let alpha = i < g.playedCount ? Self.placeholderPlayedOpacity : Self.placeholderUnplayedOpacity
                let rect = g.rect(i, height: Self.minBarHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(accent.opacity(alpha)))
            }
            return
        }

        switch style {
        case .standard, .waveformRMS, .spectrogram:
            let heights = waveform.bars(g.count, rangeDB: Self.rangeDB, exponent: Self.heightExponent)
            for i in 0..<g.count {
                fillBar(&context, g, i, height: CGFloat(heights[i]) * size.height * grow, color: accent, opacity: Self.playedOpacity)
            }

        case .waveformPeakRMS:
            let layers = waveform.peakBars(g.count, exponent: Self.peakExponent)
            for i in 0..<g.count {
                fillBar(&context, g, i, height: CGFloat(layers.peak[i]) * size.height * grow, color: accent,
                        opacity: Self.peakLayerOpacity)
                fillBar(&context, g, i, height: CGFloat(layers.rms[i]) * size.height * grow, color: accent,
                        opacity: Self.playedOpacity)
            }

        case .waveformTriBand:
            let layers = waveform.triBandBars(g.count, exponent: Self.triBandExponent)
            for i in 0..<g.count {
                fillBar(&context, g, i, height: CGFloat(layers.all[i]) * size.height * grow, color: accent,
                        opacity: Self.triBandOpacities.all)
                // The inner layers have no minimum: where they are empty there is nothing to show.
                let upper = CGFloat(layers.upper[i]) * size.height * grow
                if upper > Self.minBarHeight {
                    fillBar(&context, g, i, height: upper, color: accent, opacity: Self.triBandOpacities.upper)
                }
                let high = CGFloat(layers.high[i]) * size.height * grow
                if high > Self.minBarHeight {
                    fillBar(&context, g, i, height: high, color: accent, opacity: Self.triBandOpacities.high)
                }
            }

        case .waveformStructure:
            let heights = waveform.bars(g.count, rangeDB: Self.rangeDB, exponent: Self.heightExponent)
            let labels = waveform.segmentLabels(g.count)
            for i in 0..<g.count {
                fillBar(&context, g, i, height: CGFloat(heights[i]) * size.height * grow,
                        color: Self.palette[labels[i] % Self.palette.count], opacity: Self.playedOpacity)
            }
            let tick = Color.primary.opacity(Self.tickOpacity * grow)
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
        resolved.shading = .color(.accentColor)
        let frame = CGRect(origin: .zero, size: size)
        let split = size.width * CGFloat(fraction)

        // Played part at full opacity, the rest at its share; each clipped to its side of the position.
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: 0, width: split, height: size.height)))
            layer.opacity = Self.playedOpacity * grow
            layer.draw(resolved, in: frame)
        }
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: split, y: 0, width: size.width - split, height: size.height)))
            layer.opacity = Self.playedOpacity * Self.unplayedShare * grow
            layer.draw(resolved, in: frame)
        }
    }
}
