// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The buttons of the Playback Controls as a list that is edited in place, like `NowPlayingComponentList` (and with
/// the same rows and dragging): the eye shows or hides a button, and dragging a row moves it. It is one stack, so
/// there is no heading and no divider. The order changes once the row is dropped.
struct PlaybackControlList: View {
    @Bindable var settings: NowPlayingSettings

    @State private var drag: ReorderDrag?
    @State private var dragPosition = DragPosition()

    private var rowHeight: CGFloat { Layout.componentRowHeight }

    var body: some View {
        let items = settings.controls.items
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.control) { index, item in
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

    private func row(_ item: PlaybackControlItem, interactive: Bool = true) -> some View {
        ComponentRow(
            title: item.control.title, isVisible: item.isVisible, hasOptions: false,
            toggle: { if interactive { settings.controls.toggle(item.control) } },
            showOptions: {}
        )
    }

    // MARK: Dragging

    private func dragChanged(_ value: DragGesture.Value, count: Int) {
        if drag == nil {
            let index = Int(value.startLocation.y / rowHeight)
            guard value.startLocation.y >= 0, index < count else { return }
            // Only the geometry of `ReorderDrag` is used here: what moves is told to the layout by its index.
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
        settings.controls.move(from: finished.from, to: finished.target)
    }
}
