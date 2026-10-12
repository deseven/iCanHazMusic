// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A panel on one side of the playlist (the playlist selector, the now playing block): its content at the given width,
/// and the divider that resizes it on the side that faces the playlist. Both panels look and behave the same way;
/// `PlayerArea` decides their widths and slides them in and out (`sidePanelTransition`).
struct SidePanel<Content: View>: View {
    /// The window edge the panel is at.
    let edge: HorizontalEdge
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            if edge == .trailing { divider }
            content()
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .top)
            if edge == .leading { divider }
        }
    }

    private var divider: some View {
        SplitDivider(width: $width, range: range, blockEdge: edge)
    }
}

extension View {
    /// How a `SidePanel` at `edge` comes and goes: it slides in from that edge of the window and out to it, while the
    /// playlist takes up or gives back the room. Raised above the playlist, which the divider's hit area overlaps.
    func sidePanelTransition(_ edge: HorizontalEdge) -> some View {
        transition(.move(edge: edge == .leading ? .leading : .trailing))
            .zIndex(1)
    }
}
