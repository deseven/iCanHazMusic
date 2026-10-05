// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Thin click/drag-to-seek progress bar. While dragging it only previews (`scrubbing`); the seek itself
/// happens once, when the mouse is released.
struct SeekBar: View {
    let value: Double
    let total: Double
    /// The position being dragged to, nil when not dragging.
    @Binding var scrubbing: Double?
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let shown = scrubbing ?? value
            let fraction = total > 0 ? min(max(shown / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * fraction)
            }
            .frame(height: Self.barHeight)
            .frame(width: geo.size.width, height: geo.size.height)
            // The whole frame, including the margin above and below the drawn bar, takes the mouse.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard total > 0 else { return }
                        scrubbing = target(for: g.location.x, width: geo.size.width)
                    }
                    .onEnded { g in
                        defer { scrubbing = nil }
                        guard total > 0 else { return }
                        onSeek(target(for: g.location.x, width: geo.size.width))
                    }
            )
        }
        .frame(height: Self.barHeight + 2 * Self.hitMargin)
    }

    private static let barHeight: CGFloat = 6
    /// Extra clickable height above and below the drawn bar.
    private static let hitMargin: CGFloat = 4

    private func target(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * total
    }
}
