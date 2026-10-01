import SwiftUI

/// Pure SwiftUI, no `List`: a `ScrollView` whose content is a plain `VStack` that only
/// contains the rows near the viewport ("windowing"), padded with two spacers so the
/// document height is exact.
///
/// Why not `List`: on macOS it is backed by `SwiftUIOutlineListView` (NSOutlineView) with
/// automatic row heights, which gave scroll jumps after clicking + a "reentrant operation"
/// warning. Why not plain `LazyVStack`: it estimates the height of unrealised rows, so with
/// mixed row heights the scroll bar / content offset drift. Here every row height is known
/// up front (`PlaylistLayout.rowOffsets`), so nothing is estimated and nothing can jump.
///
/// Selection (all custom): click = select, ⌘-click = toggle, ⇧-click = range,
/// ↑/↓ = move (with ⇧ to extend).
struct VirtualPlaylistView: View {
    let playlist: Playlist
    @Binding var selection: Set<Int>

    private let layout: PlaylistLayout

    @State private var window: Range<Int>
    @State private var scrollPosition = ScrollPosition()
    @State private var viewport = ViewportBox()
    @State private var anchor: Int?   // fixed end of a shift-range
    @State private var cursor: Int?   // moving end (keyboard)
    @FocusState private var focused: Bool

    init(playlist: Playlist, selection: Binding<Set<Int>>) {
        self.playlist = playlist
        self._selection = selection
        let layout = PlaylistLayout(playlist: playlist)
        self.layout = layout
        self._window = State(initialValue: layout.rowRange(minY: 0, maxY: 800,
                                                           overscan: Layout.playlistOverscan))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: layout.rowOffsets[window.lowerBound])
                ForEach(window, id: \.self) { i in
                    PlaylistRowView(playlist: playlist, index: i, isSelected: selection.contains(i))
                        .contentShape(Rectangle())
                        .onTapGesture { click(i) }
                }
                Color.clear.frame(height: layout.totalHeight - layout.rowOffsets[window.upperBound])
            }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Range<Int>.self) { [layout] geo in
            layout.rowRange(minY: geo.visibleRect.minY, maxY: geo.visibleRect.maxY,
                            overscan: Layout.playlistOverscan)
        } action: { _, newWindow in
            window = newWindow   // only fires when the row window actually changes
        }
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
            viewport.rect = rect // plain reference, no re-render
        }
        .onChange(of: playlist.rows.count) { old, new in
            // Albums were appended (rows are only ever added at the end): refresh the window for the
            // new content and bring the first new album into view.
            guard new > old else { return }
            let top = layout.rowOffsets[old]
            window = layout.rowRange(minY: top, maxY: top + max(viewport.rect.height, 800),
                                     overscan: Layout.playlistOverscan)
            DispatchQueue.main.async { scrollPosition.scrollTo(y: top) }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
            move(press.key == .downArrow ? 1 : -1, extend: press.modifiers.contains(.shift))
            return .handled
        }
    }

    // MARK: Selection handling

    private func click(_ i: Int) {
        focused = true
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let a = anchor {
            selection = Set(min(a, i)...max(a, i))
        } else if mods.contains(.command) {
            if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            anchor = i
        } else {
            selection = [i]
            anchor = i
        }
        cursor = i
    }

    private func move(_ delta: Int, extend: Bool) {
        guard !playlist.rows.isEmpty else { return }
        let from = cursor ?? (delta > 0 ? -1 : playlist.rows.count)
        let to = min(max(from + delta, 0), playlist.rows.count - 1)
        if extend, let a = anchor ?? cursor {
            anchor = a
            selection = Set(min(a, to)...max(a, to))
        } else {
            selection = [to]
            anchor = to
        }
        cursor = to
        reveal(to)
    }

    private func reveal(_ i: Int) {
        let top = layout.rowOffsets[i], bottom = layout.rowOffsets[i + 1]
        let vp = viewport.rect
        if top < vp.minY {
            scrollPosition.scrollTo(y: top)
        } else if bottom > vp.maxY {
            scrollPosition.scrollTo(y: bottom - vp.height)
        }
    }
}

private final class ViewportBox {
    var rect: CGRect = .zero
}
