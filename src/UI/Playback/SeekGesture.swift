// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Where a click or drag at `x` of a seek bar `width` wide seeks to, in seconds of `total`.
func seekTarget(x: CGFloat, width: CGFloat, total: Double) -> Double {
    guard width > 0 else { return 0 }
    return min(max(Double(x / width), 0), 1) * total
}

extension View {
    /// Click/drag-to-seek for a seek bar `width` wide, shared by all styles: the whole frame takes the mouse. While
    /// dragging it only previews (`scrubbing`); the seek itself happens once, when the mouse is released.
    func seekGesture(width: CGFloat, total: Double, scrubbing: Binding<Double?>,
                     onSeek: @escaping (Double) -> Void) -> some View {
        contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard total > 0 else { return }
                        scrubbing.wrappedValue = seekTarget(x: g.location.x, width: width, total: total)
                    }
                    .onEnded { g in
                        defer { scrubbing.wrappedValue = nil }
                        guard total > 0 else { return }
                        onSeek(seekTarget(x: g.location.x, width: width, total: total))
                    }
            )
    }
}
