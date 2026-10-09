// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Thin click/drag-to-seek progress bar (the "Default" seek bar style). While dragging it only previews
/// (`scrubbing`); the seek itself happens once, when the mouse is released.
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
            .frame(height: Layout.seekbarBarHeight)
            .frame(width: geo.size.width, height: geo.size.height)
            // The whole frame, including the margin above and below the drawn bar, takes the mouse.
            .seekGesture(width: geo.size.width, total: total, scrubbing: $scrubbing, onSeek: onSeek)
        }
        .frame(height: Layout.seekbarHeight)
    }
}
