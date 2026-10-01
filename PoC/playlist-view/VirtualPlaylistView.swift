import SwiftUI

/// Pure SwiftUI, no `List`: a `ScrollView` whose content is a plain `VStack` that only
/// contains the rows near the viewport ("windowing"), padded with two spacers so the
/// document height is exact.
///
/// Why not `List`: on macOS it is backed by `SwiftUIOutlineListView` (NSOutlineView) with
/// automatic row heights, which gave scroll jumps after clicking + a "reentrant operation"
/// warning. Why not plain `LazyVStack`: it estimates the height of unrealised rows, so with
/// mixed row heights the scroll bar / content offset drift. Here every row height is known
/// up front (`Playlist.rowOffsets`), so nothing is estimated and nothing can jump.
///
/// Selection (all custom): click = select, ⌘-click = toggle, ⇧-click = range,
/// ↑/↓ = move (with ⇧ to extend).
struct VirtualPlaylistView: View {
    let playlist: Playlist
    @Binding var selection: Set<Int>

    @State private var window: Range<Int>
    @State private var scrollPosition = ScrollPosition()
    @State private var viewport = ViewportBox()
    @State private var anchor: Int?   // fixed end of a shift-range
    @State private var cursor: Int?   // moving end (keyboard)
    @FocusState private var focused: Bool

    private static let overscan: CGFloat = 600

    init(playlist: Playlist, selection: Binding<Set<Int>>) {
        self.playlist = playlist
        self._selection = selection
        self._window = State(initialValue: playlist.rowRange(minY: 0, maxY: 800, overscan: Self.overscan))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: playlist.rowOffsets[window.lowerBound])
                ForEach(window, id: \.self) { i in
                    PlaylistRowView(playlist: playlist, index: i, isSelected: selection.contains(i))
                        .contentShape(Rectangle())
                        .onTapGesture { click(i) }
                }
                Color.clear.frame(height: playlist.totalHeight - playlist.rowOffsets[window.upperBound])
            }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Range<Int>.self) { geo in
            playlist.rowRange(minY: geo.visibleRect.minY, maxY: geo.visibleRect.maxY, overscan: Self.overscan)
        } action: { _, newWindow in
            window = newWindow   // only fires when the row window actually changes
        }
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
            viewport.rect = rect // plain reference, no re-render
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
        let top = playlist.rowOffsets[i], bottom = playlist.rowOffsets[i + 1]
        let vp = viewport.rect
        if top < vp.minY {
            scrollPosition.scrollTo(y: top)
        } else if bottom > vp.maxY {
            scrollPosition.scrollTo(y: bottom - vp.height)
        }
    }
}

final class ViewportBox {
    var rect: CGRect = .zero
}

// MARK: - Rows

struct PlaylistRowView: View {
    let playlist: Playlist
    let index: Int
    let isSelected: Bool

    var body: some View {
        let row = playlist.rows[index]
        if let track = playlist.track(for: row) {
            TrackRowContent(track: track)
                .frame(height: RowMetrics.track)
                .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        } else {
            AlbumHeaderContent(album: playlist.albums[row.albumIndex], isSelected: isSelected)
                .frame(height: RowMetrics.header)
                .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.primary.opacity(0.06))
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        }
    }
}

struct AlbumHeaderContent: View {
    let album: Album
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: CoverCache.image(for: album))
                .resizable()
                .frame(width: CoverCache.size, height: CoverCache.size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 0) {
                Text(album.artist).font(.system(size: 13, weight: .bold))
                Text(album.title).font(.system(size: 12))
                Text(String(album.year))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrackRowContent: View {
    let track: Track

    var body: some View {
        HStack(spacing: 0) {
            Text(String(format: "%02d", track.number))
                .monospacedDigit()
                .opacity(0.65)
                .frame(width: 44, alignment: .trailing)
            Text(track.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
            Text(track.durationText)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
            Text(track.codec)
                .opacity(0.65)
                .frame(width: 110, alignment: .leading)
                .padding(.leading, 12)
        }
        .font(.system(size: 12))
    }
}
