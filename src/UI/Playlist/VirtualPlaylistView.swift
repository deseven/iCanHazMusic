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
/// ↑/↓ = move (with ⇧ to extend), double click = `onActivate` with the row id.
///
/// Every row has a context menu (Play, Reveal in Finder, Reload Tag(s), Remove from Playlist, see
/// `PlaylistItemActions`); the keys are Return, ⌘R and Backspace. A right click on a row outside the selection
/// selects that row first. The actions apply to the selection.
///
/// `cursor` is the row the selection last moved to (the moving end of a range). `playingRow` gets the play
/// symbol; when it changes and `cursorFollowsPlayback` is on, the selection and cursor move to it and it is
/// scrolled into view.
struct VirtualPlaylistView: View {
    let playlist: Playlist
    @Binding var selection: Set<Int>
    @Binding var cursor: Int?
    let playingRow: Int?
    let cursorFollowsPlayback: Bool
    let onActivate: (Int) -> Void

    private let layout: PlaylistLayout

    @State private var window: Range<Int>
    @State private var scrollPosition = ScrollPosition()
    @State private var viewport = ViewportBox()
    @State private var anchor: Int?   // fixed end of a shift-range
    @State private var pointer = PointerBox()
    @State private var eventMonitor: Any?
    @FocusState private var focused: Bool

    init(playlist: Playlist, selection: Binding<Set<Int>>, cursor: Binding<Int?>, playingRow: Int?,
         cursorFollowsPlayback: Bool, onActivate: @escaping (Int) -> Void) {
        self.playlist = playlist
        self._selection = selection
        self._cursor = cursor
        self.playingRow = playingRow
        self.cursorFollowsPlayback = cursorFollowsPlayback
        self.onActivate = onActivate
        let layout = PlaylistLayout(playlist: playlist)
        self.layout = layout
        self._window = State(initialValue: layout.rowRange(minY: 0, maxY: 800,
                                                           overscan: Layout.playlistOverscan))
    }

    var body: some View {
        // The window can be stale for a moment after the playlist shrank (its update comes with the change handler).
        let shown = min(window.lowerBound, layout.rowCount)..<min(window.upperBound, layout.rowCount)
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: layout.rowOffsets[shown.lowerBound])
                ForEach(shown, id: \.self) { i in
                    PlaylistRowView(playlist: playlist, index: i, isSelected: selection.contains(i),
                                                        isPlaying: i == playingRow)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            click(i)
                            // A separate count: 2 gesture would delay every single click.
                            if NSApp.currentEvent?.clickCount == 2 { onActivate(i) }
                        }
                        .onHover { inside in
                            if inside { pointer.row = i } else if pointer.row == i { pointer.row = nil }
                        }
                        .contextMenu { contextMenu }
                }
                Color.clear.frame(height: layout.totalHeight - layout.rowOffsets[shown.upperBound])
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
            if let top = playlist.appendedFromRow, new > old {
                // Tracks were added: refresh the window for the new content and bring the first new row into view.
                let offset = layout.rowOffsets[min(top, layout.rowCount)]
                window = layout.rowRange(minY: offset, maxY: offset + max(viewport.rect.height, 800),
                                         overscan: Layout.playlistOverscan)
                DispatchQueue.main.async { scrollPosition.scrollTo(y: offset) }
            } else {
                window = layout.rowRange(minY: viewport.rect.minY, maxY: max(viewport.rect.maxY, 800),
                                         overscan: Layout.playlistOverscan)
            }
        }
        .onChange(of: playlist.isFlat) { _, _ in clearSelection() }
        .onChange(of: playingRow) { _, row in
            guard cursorFollowsPlayback, let row, playlist.rows.indices.contains(row) else { return }
            selection = [row]
            anchor = row
            cursor = row
            reveal(row)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
            move(press.key == .downArrow ? 1 : -1, extend: press.modifiers.contains(.shift))
            return .handled
        }
        .background {
            // ⌘R: a shortcut of its own, as no menu has the item.
            Button("Reload Tag(s)") { reloadSelected() }
                .keyboardShortcut("r", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear {
            installEventMonitor()
            showPlayingRow()
        }
        .onDisappear {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }
    }

    /// A playlist opened while playback runs from it: scroll to the playing track (the selection is set by the
    /// parent, which owns it).
    private func showPlayingRow() {
        guard let row = playingRow, playlist.rows.indices.contains(row) else { return }
        anchor = row
        let top = max(0, layout.rowOffsets[row] - Layout.albumHeaderRowHeight)   // the album header above stays visible
        window = layout.rowRange(minY: top, maxY: top + 800, overscan: Layout.playlistOverscan)
        DispatchQueue.main.async { scrollPosition.scrollTo(y: top) }
    }

    // MARK: Context menu

    private var contextMenu: some View {
        Group {
            Button("Play") { playSelected() }
                .keyboardShortcut(.return, modifiers: [])
            Button("Reveal in Finder") { PlaylistItemActions.reveal(selection) }
            Button("Reload Tag(s)") { reloadSelected() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Remove from Playlist") { removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
        }
    }

    /// - A right click (or ⌃-click) outside the selection selects the row under the pointer before the menu opens.
    ///   The menu items read the selection when they are chosen, so they act on what is selected by then.
    /// - Return plays and Backspace removes the selection. This is a monitor and not `onKeyPress`, which
    ///   left Backspace unhandled (the system beeped); the key codes are the same on every layout.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        let pointer = pointer
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .keyDown]) { event in
            guard event.window === Dialogs.hostWindow else { return event }

            if event.type == .keyDown {
                let plain = event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
                guard plain, !event.isARepeat else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard focused, !selection.isEmpty else { return false }
                    switch event.keyCode {
                    case 36, 76:        // Return, keypad Enter
                        playSelected()
                    case 51, 117:       // Backspace, forward delete
                        removeSelected()
                    default:
                        return false
                    }
                    return true
                }
                return handled ? nil : event
            }

            let opensMenu = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard opensMenu, let row = pointer.row else { return event }
            MainActor.assumeIsolated {
                focused = true
                if !selection.contains(row) {
                    selection = [row]
                    anchor = row
                    cursor = row
                }
            }
            return event
        }
    }

    // MARK: Actions

    private func playSelected() {
        guard let row = selection.min() else { return }
        onActivate(row)
    }

    private func reloadSelected() {
        let rows = selection
        guard !rows.isEmpty, !ImportCoordinator.shared.isBusy else { return }
        Task {
            await PlaylistItemActions.reloadTags(rows)
            clearSelection()
        }
    }

    private func removeSelected() {
        let rows = selection
        guard !rows.isEmpty, !ImportCoordinator.shared.isBusy else { return }
        Task {
            await PlaylistItemActions.remove(rows)
            clearSelection()
        }
    }

    private func clearSelection() {
        selection = []
        anchor = nil
        cursor = nil
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

/// The row under the mouse pointer (a plain reference: changes don't re-render).
private final class PointerBox {
    var row: Int?
}
