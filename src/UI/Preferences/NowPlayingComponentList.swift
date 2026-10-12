// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The components of the now playing block as a list that is edited in place: the eye symbol shows or hides one, the
/// gear (for those that have options) opens a sheet with them, and dragging a row moves it, among the others of its stack or to the other stack.
///
/// The two stacks are one list: `Top`, the components of the top stack, then `Bottom` (a row that cannot be dragged),
/// then the components of the bottom stack. A component dragged past the `Bottom` row changes stacks, and an empty
/// stack is just one with its heading next to the one before or after it. Dragging works like the one in the playlist:
/// all rows are equally tall, the dragged one follows the pointer vertically (`ReorderDrag`, drawn by
/// `DraggedItemOverlay`), the rows it passes make room, and the layout changes once it is dropped.
struct NowPlayingComponentList: View {
    @Bindable var settings: NowPlayingSettings

    @State private var drag: ReorderDrag?
    @State private var dragPosition = DragPosition()
    /// The component whose options sheet is open.
    @State private var optionsOf: NowPlayingComponent?

    private var rowHeight: CGFloat { Layout.componentRowHeight }

    var body: some View {
        let slots = settings.layout.slots
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                SectionHeading(title: "Top", symbol: "arrow.up.to.line")
                    .frame(height: rowHeight)
                ForEach(Array(slots.enumerated()), id: \.element.key) { index, slot in
                    row(index, slot)
                        .frame(height: rowHeight)
                        .offset(y: drag?.shift(of: index) ?? 0)
                }
            }
            .animation(.easeOut(duration: 0.12), value: drag?.target)

            if let drag, case .item(let item) = slots[drag.from] {
                DraggedItemOverlay(position: dragPosition, content: ComponentRow(
                    title: item.component.title, isVisible: item.isVisible, hasOptions: item.component.hasOptions,
                    toggle: {}, showOptions: {}))
                    .frame(height: rowHeight)
            }
        }
        .componentListBox()
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { dragChanged($0, slots: slots) }
                .onEnded { _ in dragEnded() }
        )

        .sheet(item: $optionsOf) { component in
            ComponentOptionsSheet(component: component, settings: settings)
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ slot: NowPlayingLayout.Slot) -> some View {
        switch slot {
        case .item(let item):
            ComponentRow(
                title: item.component.title, isVisible: item.isVisible, hasOptions: item.component.hasOptions,
                toggle: { settings.layout.toggle(item.component) },
                showOptions: { optionsOf = item.component }
            )
            .opacity(drag?.from == index ? 0 : 1)   // the floating copy is what is seen
        case .divider:
            SectionHeading(title: "Bottom", symbol: "arrow.down.to.line")
        }
    }

    // MARK: Dragging

    private func dragChanged(_ value: DragGesture.Value, slots: [NowPlayingLayout.Slot]) {
        if drag == nil {
            // Rows start below the heading of the top stack.
            guard value.startLocation.y >= rowHeight else { return }
            let index = Int((value.startLocation.y - rowHeight) / rowHeight)
            guard slots.indices.contains(index), case .item = slots[index] else { return }
            let rowTop = rowHeight * CGFloat(index + 1)
            // Only the geometry of `ReorderDrag` is used here: the item to move is told to the layout by its slot.
            drag = ReorderDrag(kind: .track, from: index, range: 0..<slots.count, itemHeight: rowHeight,
                               top: rowHeight, grab: value.startLocation.y - rowTop, movedID: 1,
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
        settings.layout.move(from: finished.from, to: finished.target)
    }
}

private extension NowPlayingLayout.Slot {
    var key: String {
        switch self {
        case .item(let item): item.component.rawValue
        case .divider: "divider"
        }
    }
}

extension View {
    /// The look of the lists of `NowPlayingComponentList` and `ToggleItemList`: a bordered box with rounded corners.
    func componentListBox() -> some View {
        background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            .contentShape(Rectangle())
    }
}

/// A row of a list: the grip, the name, the gear that opens its options (if it has any), and the eye that shows or hides it.
struct ComponentRow: View {
    let title: String
    let isVisible: Bool
    let hasOptions: Bool
    let toggle: () -> Void
    let showOptions: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(isVisible ? .primary : .secondary)
            Spacer(minLength: 0)
            if hasOptions {
                Button(action: showOptions) {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(Color.secondary)
                        .frame(width: 26, height: Layout.componentRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Options")
            }
            Button(action: toggle) {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                    .foregroundStyle(isVisible ? Color.primary : Color.secondary)
                    .frame(width: 26, height: Layout.componentRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isVisible ? "Hide" : "Show")
        }
        .padding(.horizontal, 8)
    }
}

/// The heading of a stack.
private struct SectionHeading: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.12))
    }
}
