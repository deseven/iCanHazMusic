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
/// Every row has a context menu (Play, Enqueue / Remove from queue, Reveal in Finder, Reload Tag(s), Remove
/// from Playlist, see `PlaylistItemActions`); the keys are Return, Space (the queue), ⌘R and Backspace, and ↑/↓ move
/// (all of them work whatever has the key focus in the main window, see `installEventMonitor`). A right click on
/// a row outside the selection selects that row first. The actions apply to the selection.
///
/// With `queue` it shows the play queue instead of a playlist: `playlist` is then a flat one with a track per queue entry
/// (row = place in the queue). Nothing can be played from there, the only changes are removing entries (Backspace) and
/// going to a track in its playlist. Otherwise (`playlistName`) tracks that are queued show their place in the
/// queue where the play symbol goes.
///
/// `cursor` is the row the selection last moved to (the moving end of a range). `playingRow` gets the play
/// symbol; when it changes and `cursorFollowsPlayback` is on, the selection and cursor move to it and it is
/// scrolled into view.
///
/// `revealRow` is a request from the parent to scroll to a row (the selection is set by the parent, which owns it);
/// the view resets it to `nil` once it has taken it up.
struct VirtualPlaylistView: View {
    let playlist: Playlist
    @Binding var selection: Set<Int>
    @Binding var cursor: Int?
    @Binding var revealRow: Int?
    let playingRow: Int?
    let cursorFollowsPlayback: Bool
    let showAlbumArt: Bool
    let onActivate: (Int) -> Void
    /// The name of the playlist shown (queue entries refer to tracks by it).
    let playlistName: String
    /// Shows the queue: its entries, in the order of the rows of `playlist`.
    let queue: [QueueEntry]?
    /// Queue rows name the playlist of their track (when there are several).
    let showsQueuePlaylists: Bool

    private let playback = PlaybackState.shared
    private let layout: PlaylistLayout

    @State private var window: Range<Int>
    @State private var scrollPosition = ScrollPosition()
    @State private var viewport = ViewportBox()
    @State private var scrollBox = ScrollBox()
    @State private var anchor: Int?   // fixed end of a shift-range
    @State private var pointer = PointerBox()
    @State private var eventMonitor: Any?
    @State private var keys = KeyHandlerBox()

    init(playlist: Playlist, selection: Binding<Set<Int>>, cursor: Binding<Int?>, revealRow: Binding<Int?>,
         playingRow: Int?, cursorFollowsPlayback: Bool, showAlbumArt: Bool, playlistName: String = "",
         queue: [QueueEntry]? = nil, showsQueuePlaylists: Bool = false, onActivate: @escaping (Int) -> Void) {
        self.playlistName = playlistName
        self.queue = queue
        self.showsQueuePlaylists = showsQueuePlaylists
        self.playlist = playlist
        self._selection = selection
        self._cursor = cursor
        self._revealRow = revealRow
        self.playingRow = playingRow
        self.cursorFollowsPlayback = cursorFollowsPlayback
        self.showAlbumArt = showAlbumArt
        self.onActivate = onActivate
        let layout = PlaylistLayout(playlist: playlist, showAlbumArt: showAlbumArt)
        self.layout = layout
        self._window = State(initialValue: layout.rowRange(minY: 0, maxY: 800,
                                                           overscan: Layout.playlistOverscan))
    }

    var body: some View {
        // The window can be stale for a moment after the playlist shrank (its update comes with the change handler).
        let shown = min(window.lowerBound, layout.rowCount)..<min(window.upperBound, layout.rowCount)
        // The event monitor outlives this struct value, so it calls whatever handler the latest body left here (a
        // plain reference, not observed: no re-render).
        let _ = keys.handler = { event in handleKey(event) }
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: layout.rowOffsets[shown.lowerBound])
                ForEach(shown, id: \.self) { i in
                    PlaylistRowView(playlist: playlist, index: i, isSelected: selection.contains(i),
                                    isPlaying: i == playingRow, showAlbumArt: showAlbumArt,
                                    queuePosition: queuePosition(at: i), queued: queuedRow(at: i))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            click(i)
                            // A separate count: 2 gesture would delay every single click.
                            if NSApp.currentEvent?.clickCount == 2 { onActivate(i) }
                        }
                        .onHover { inside in
                            if inside { pointer.row = i } else if pointer.row == i { pointer.row = nil }
                        }
                        .contextMenu { contextMenu(for: i) }
                }
                Color.clear.frame(height: layout.totalHeight - layout.rowOffsets[shown.upperBound])
            }
            .background(ScrollViewFinder(box: scrollBox))
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
        .onChange(of: showAlbumArt) { _, _ in
            // The header height changed: the rows' offsets did too.
            window = layout.rowRange(minY: viewport.rect.minY, maxY: max(viewport.rect.maxY, 800),
                                     overscan: Layout.playlistOverscan)
        }
        .onChange(of: playingRow) { _, row in
            guard cursorFollowsPlayback, let row, playlist.rows.indices.contains(row) else { return }
            selection = [row]
            anchor = row
            cursor = row
            reveal(row, deferred: true)
        }
        .onChange(of: revealRow) { _, _ in showRevealedRow() }

        .onAppear {
            installEventMonitor()
            showRevealedRow()
        }
        .onDisappear {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }
    }

    /// The parent asked for a row to be shown (a playlist was opened, see `PlayerArea`): scroll to it, in the middle
    /// of the view. The scroll view may not have been found yet if the playlist is shown for the first time, so
    /// this tries a few more times.
    private func showRevealedRow() {
        guard let row = revealRow else { return }
        revealRow = nil
        guard playlist.rows.indices.contains(row) else { return }
        anchor = row
        scrollToCenter(row, attempts: 5)
    }

    private func scrollToCenter(_ row: Int, attempts: Int) {
        DispatchQueue.main.async {
            if !scrollToReveal(row, centered: true), attempts > 1 { scrollToCenter(row, attempts: attempts - 1) }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for row: Int) -> some View {
        if queue != nil {
            Button("Remove from Queue") { removeFromQueueSelected() }
                .keyboardShortcut(.delete, modifiers: [])
            Divider()
            Button("Show in Playlist") { showInPlaylist() }
            Button("Reveal in Finder") { PlaylistItemActions.reveal(selection, in: playlist) }
        } else {
            Button("Play") { playSelected() }
                .keyboardShortcut(.return, modifiers: [])
            if playback.queue.isEnabled {
                // The title is about what the menu will act on: the selection, or the row if that is outside it.
                let toggle = PlaylistItemActions.queueToggle(for: selection.contains(row) ? selection : [row])
                Button(toggle.title) { toggleQueued() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(toggle.isUnavailable)
            }

            Divider()
            Button("Reveal in Finder") { PlaylistItemActions.reveal(selection) }
            Button("Reload Tag(s)") { reloadSelected() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Remove from Playlist") { removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
        }
    }

    /// The place of the track of a row in the queue (nothing for headers, or while the queue is what is shown).
    private func queuePosition(at row: Int) -> Int? {
        guard queue == nil, !playback.queue.isEmpty, let track = playlist.track(for: playlist.rows[row]) else { return nil }
        return playback.queue.position(of: QueueEntry(playlist: playlistName, id: track.id))
    }

    private func queuedRow(at row: Int) -> QueuedRow? {
        guard let queue, queue.indices.contains(row) else { return nil }
        return QueuedRow(number: row + 1, playlist: showsQueuePlaylists ? queue[row].playlist : nil)
    }

    /// - A right click (or ⌃-click) outside the selection selects the row under the pointer before the menu opens.
    ///   The menu items read the selection when they are chosen, so they act on what is selected by then.
    /// - The playlist is the keyboard target of the whole main window, whatever has the key focus (the sidebar
    ///   after choosing a playlist, a button...): ↑/↓, Return, Space and Backspace are handled here, `handleKey`.
    ///   This is a monitor and not `onKeyPress`, which depends on focus and left Backspace unhandled (the system
    ///   beeped); the key codes are the same on every layout. Text being edited keeps its keys.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        let pointer = pointer
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .keyDown]) { event in
            guard event.window === Dialogs.hostWindow else { return event }

            if event.type == .keyDown {
                guard !(event.window?.firstResponder is NSText) else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard [[], .shift, .command].contains(modifiers) else { return event }
                let handled = MainActor.assumeIsolated { keys.handler?(event) ?? false }
                return handled ? nil : event
            }

            let opensMenu = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard opensMenu, let row = pointer.row else { return event }
            MainActor.assumeIsolated {
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

    /// A key of the main window (⇧ or ⌘ at most). ↑/↓ move the selection (⇧ extends it, holding repeats); Return,
    /// Space, Backspace and ⌘R act on the selection, once per press, like the context menu's items. Returns whether
    /// the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        let code = event.keyCode
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isDisjoint(with: .command), code == 125 || code == 126 {   // Down, up
            move(code == 125 ? 1 : -1, extend: modifiers == .shift)
            return true
        }
        guard !event.isARepeat, !selection.isEmpty else { return false }
        if modifiers == .command {
            guard event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
            reloadSelected()    // Reload Tag(s)
            return true
        }
        guard modifiers.isEmpty else { return false }
        let showsQueue = queue != nil
        switch code {
        case 36, 76:        // Return, keypad Enter
            if !showsQueue { playSelected() }
        case 51, 117:       // Backspace, forward delete
            if showsQueue { removeFromQueueSelected() } else { removeSelected() }
        case 49:            // Space
            guard !showsQueue, playback.queue.isEnabled else { return false }
            toggleQueued()
        default:
            return false
        }
        return true
    }

    private func playSelected() {
        guard let row = selection.min() else { return }
        onActivate(row)
    }

    /// Adds the selection to the queue, or takes it out if it is all in there.
    private func toggleQueued() {
        PlaylistItemActions.toggleQueue(selection)
    }

    private func removeFromQueueSelected() {
        guard let queue else { return }
        playback.dequeue(Set(selection.filter { queue.indices.contains($0) }.map { queue[$0] }))
    }

    /// Opens the playlist of the first selected queue entry, with its track selected.
    private func showInPlaylist() {
        guard let queue, let row = selection.min(), queue.indices.contains(row) else { return }
        PlaylistStore.shared.reveal(trackID: queue[row].id, inPlaylist: queue[row].playlist)
    }

    private func reloadSelected() {
        let rows = selection
        guard queue == nil, !rows.isEmpty, !ImportCoordinator.shared.isBusy else { return }
        Task {
            await PlaylistItemActions.reloadTags(rows)
            clearSelection()
        }
    }

    private func removeSelected() {
        let rows = selection
        guard queue == nil, !rows.isEmpty, !ImportCoordinator.shared.isBusy else { return }
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

    /// Scrolls the minimum needed to bring row `i` into view.
    ///
    /// This moves the `NSScrollView` behind the SwiftUI `ScrollView` directly: `ScrollPosition.scrollTo(y:)` lands
    /// 52 px away from where it is told to (the title bar inset: its offsets don't share an origin with
    /// `visibleRect`), which only a delayed correction could fix, visibly jumping. The row is located in the clip
    /// view's own coordinates and the content moved by exactly what is missing, inside the insets.
    ///
    /// `deferred`: for changes not caused by a key press (a transport command), which is still being applied by
    /// SwiftUI; the scroll happens on the next run-loop turn.
    private func reveal(_ i: Int, deferred: Bool = false) {
        if deferred {
            DispatchQueue.main.async { scrollToReveal(i) }
        } else {
            scrollToReveal(i)
        }
    }

    /// `centered`: the row ends up in the middle of the view even if it is visible already (a row near the
    /// start or the end of the playlist is as close to it as the content allows).
    /// Returns `false` if the scroll view isn't known yet, so it can be tried again.
    @discardableResult
    private func scrollToReveal(_ i: Int, centered: Bool = false) -> Bool {
        guard layout.rowOffsets.indices.contains(i + 1) else { return true }
        guard let scrollView = scrollBox.scrollView, let anchor = scrollBox.anchor else { return false }
        let clip = scrollView.contentView
        guard clip.isFlipped else {
            Log.error("playlist scroll view is not flipped, can't scroll to row \(i)")
            return true
        }

        // The row in the clip view's coordinates (the same ones as its bounds, which move when scrolling).
        let rowRect = clip.convert(NSRect(x: 0, y: layout.rowOffsets[i], width: 1,
                                          height: layout.rowOffsets[i + 1] - layout.rowOffsets[i]), from: anchor)
        let insets = scrollView.contentInsets
        let visibleTop = clip.bounds.minY + insets.top
        let visibleBottom = clip.bounds.maxY - insets.bottom

        var origin = clip.bounds.origin
        if centered {
            origin.y += rowRect.midY - (visibleTop + visibleBottom) / 2
        } else if rowRect.minY < visibleTop {
            origin.y -= visibleTop - rowRect.minY
        } else if rowRect.maxY > visibleBottom {
            origin.y += rowRect.maxY - visibleBottom
        } else {
            return true
        }
        origin = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin

        // Rows have to exist where we're going, whether or not SwiftUI has caught up with the scroll by then.
        let height = clip.bounds.height
        window = layout.rowRange(minY: layout.rowOffsets[i] - height, maxY: layout.rowOffsets[i + 1] + height,
                                 overscan: Layout.playlistOverscan)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}

/// Where the key monitor finds the current key handler (see `VirtualPlaylistView.body`).
private final class KeyHandlerBox {
    var handler: ((NSEvent) -> Bool)?
}

private final class ViewportBox {
    var rect: CGRect = .zero
}

/// The `NSScrollView` behind the playlist's `ScrollView`, and a view that has the content's frame (the origin
/// row offsets are measured from).
private final class ScrollBox {
    weak var scrollView: NSScrollView?
    weak var anchor: NSView?
}

/// Placed in the scrolled content (as its background): finds the enclosing `NSScrollView` once it is in the
/// window.
private struct ScrollViewFinder: NSViewRepresentable {
    let box: ScrollBox

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }   // y grows downwards, like the row offsets
    }

    func makeNSView(context: Context) -> NSView {
        FlippedView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.anchor = view
        guard box.scrollView == nil else { return }
        DispatchQueue.main.async { box.scrollView = view.enclosingScrollView }
    }
}

/// The row under the mouse pointer (a plain reference: changes don't re-render).
private final class PointerBox {
    var row: Int?
}
