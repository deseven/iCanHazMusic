// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// One stack of items (no headings, no dividers) edited in place, with the rows and the dragging of
/// `NowPlayingComponentList`: the eye shows or hides an item (`toggle`), dragging a row moves it (`move(from, to)`,
/// called once the row is dropped). What the items are is up to the owner: `PlaybackControlList`, `PlaylistColumnList`.
struct ToggleItemList<ID: Hashable>: View {
    struct Item {
        let id: ID
        let title: String
        let isVisible: Bool
    }

    let items: [Item]
    let toggle: (ID) -> Void
    let move: (Int, Int) -> Void

    @State private var drag: ReorderDrag?
    @State private var dragPosition = DragPosition()

    private var rowHeight: CGFloat { Layout.componentRowHeight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                        .frame(height: rowHeight)
                        .opacity(drag?.from == index ? 0 : 1)   // the floating copy is what is seen
                        .offset(y: drag?.shift(of: index) ?? 0)
                }
            }
            .animation(.easeOut(duration: 0.12), value: drag?.target)

            if let drag, items.indices.contains(drag.from) {
                DraggedItemOverlay(position: dragPosition, content: row(items[drag.from], interactive: false))
                    .frame(height: rowHeight)
            }
        }
        .componentListBox()
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { dragChanged($0, count: items.count) }
                .onEnded { _ in dragEnded() }
        )
    }

    private func row(_ item: Item, interactive: Bool = true) -> some View {
        ComponentRow(
            title: item.title, isVisible: item.isVisible, hasOptions: false,
            toggle: { if interactive { toggle(item.id) } },
            showOptions: {}
        )
    }

    // MARK: Dragging

    private func dragChanged(_ value: DragGesture.Value, count: Int) {
        if drag == nil {
            let index = Int(value.startLocation.y / rowHeight)
            guard value.startLocation.y >= 0, index < count else { return }
            // Only the geometry of `ReorderDrag` is used here: what moves is told to the owner by its index.
            drag = ReorderDrag(kind: .track, from: index, range: 0..<count, itemHeight: rowHeight,
                               top: 0, grab: value.startLocation.y - rowHeight * CGFloat(index), movedID: 1,
                               collapsed: nil, target: index)
        }
        guard var current = drag else { return }
        let y = current.drawnY(pointerY: value.location.y)
        dragPosition.y = y
        let target = current.target(forDrawnY: y)
        if target != current.target {
            current.target = target
            drag = current
        }
    }

    private func dragEnded() {
        guard let finished = drag else { return }
        drag = nil
        move(finished.from, finished.target)
    }
}
