// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Vertical draggable divider. Visually a 1pt line, with a wider invisible hit area.
/// Dragging towards the block makes it narrower, dragging away from it wider.
struct SplitDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    /// The side of the divider the block whose `width` it changes is on.
    let blockEdge: HorizontalEdge

    @State private var startWidth: CGFloat?

    var body: some View {
        // Layout-wise the divider is only 1pt wide; the (wider) hit area is an overlay that
        // extends over the neighbouring views, and the divider is raised above them.
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: Layout.dividerLineWidth)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: Layout.dividerHitWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                let delta = blockEdge == .trailing ? -value.translation.width : value.translation.width
                                width = min(max(start + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            )
            .zIndex(1)
    }
}
