// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The "Waveform" seek bar style: the loudness of the track over time as mirrored, rounded bars in the accent colour on
/// a transparent background. The bars are half-transparent; the played ones are drawn at full opacity, so they
/// "light up" as the track plays. The current position is a thicker line in a darker shade of the accent colour.
/// Click/drag seeks like the default bar (`seekGesture`).
///
/// While the waveform isn't there (being made, or the track can't be analysed) the bars are a dimmed dotted line at
/// minimum height; the played bars and the line work as usual, so the bar is usable from the first frame.
struct WaveformSeekBar: View {
    let value: Double
    let total: Double
    /// The position being dragged to, nil when not dragging.
    @Binding var scrubbing: Double?
    let onSeek: (Double) -> Void

    private let service = WaveformService.shared

    var body: some View {
        // Read here, not inside the GeometryReader, so the view is redrawn when the waveform arrives.
        let waveform = service.current
        GeometryReader { geo in
            let shown = scrubbing ?? value
            let fraction = total > 0 ? min(max(shown / total, 0), 1) : 0
            WaveformBars(waveform: waveform, fraction: fraction, grow: waveform == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.3), value: waveform != nil)
                .frame(width: geo.size.width, height: geo.size.height)
                .seekGesture(width: geo.size.width, total: total, scrubbing: $scrubbing, onSeek: onSeek)
        }
        .frame(height: Layout.waveformSeekbarHeight)
    }
}

/// The drawing. Animatable in `grow` (0 = every bar at minimum height, 1 = the waveform), so the bars rise when the
/// waveform arrives.
private struct WaveformBars: View, Animatable {
    let waveform: Waveform?
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
    /// Opacity of the bars not played yet / already played.
    private static let unplayedOpacity = 0.5
    private static let playedOpacity = 1.0
    /// The same while there is no waveform (the dotted line).
    private static let placeholderUnplayedOpacity = 0.25
    private static let placeholderPlayedOpacity = 0.5
    private static let positionLineWidth: CGFloat = 2.5
    /// How much black is mixed into the accent colour for the position line.
    private static let positionLineDarkening = 0.45

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let count = max(1, Int(size.width / Self.slotWidth))
            let slot = size.width / CGFloat(count)
            let barWidth = slot * Self.barShare
            let heights = waveform.map { $0.bars(count, rangeDB: Self.rangeDB, exponent: Self.heightExponent) }
            let playedCount = Int((fraction * Double(count)).rounded())

            let hasWaveform = waveform != nil
            let unplayedColor = Color.accentColor.opacity(hasWaveform ? Self.unplayedOpacity : Self.placeholderUnplayedOpacity)
            let playedColor = Color.accentColor.opacity(hasWaveform ? Self.playedOpacity : Self.placeholderPlayedOpacity)

            // One fill per bar: merging hundreds of thin bars into one path made the rasteriser smear coverage between
            // them (shapes that followed the playback position).
            for i in 0..<count {
                let level = heights.map { CGFloat($0[i]) * CGFloat(grow) } ?? 0
                let height = max(Self.minBarHeight, level * size.height)
                let rect = CGRect(x: CGFloat(i) * slot + (slot - barWidth) / 2, y: (size.height - height) / 2,
                                  width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(barWidth, height) / 2),
                             with: .color(i < playedCount ? playedColor : unplayedColor))
            }

            // The current position, kept inside the frame at the ends so it isn't cut off.
            let x = size.width * CGFloat(fraction)
            let half = Self.positionLineWidth / 2
            let center = min(max(x, half), size.width - half)
            context.fill(Path(CGRect(x: center - half, y: 0, width: Self.positionLineWidth, height: size.height)),
                         with: .color(Color.accentColor.mix(with: .black, by: Self.positionLineDarkening)))
        }
    }
}
