import SwiftUI

/// The search window: a floating panel in the style of Spotlight, Alfred or Raycast, which takes the keyboard focus
/// for as long as it is there. It goes away when a result is chosen, with Esc, or as soon as something else is
/// clicked or comes to the front.
///
/// It doesn't activate the app (a non-activating panel), so it works the same from the Playlist menu and from the
/// global hotkey, and cancelling it leaves the user where they were. Choosing a result starts it: a track or an
/// album in its playlist, a playlist from its start; the playlist is opened for that.
@MainActor
final class SearchPanel {
    static let shared = SearchPanel()

    private var panel: Panel?
    private var resignObserver: NSObjectProtocol?

    private init() {}

    var isShown: Bool { panel != nil }

    /// Opens the window, or closes it if it is open (so the hotkey works both ways).
    func toggle() {
        if isShown { close() } else { show() }
    }

    func show() {
        guard panel == nil else { return }
        guard !ImportCoordinator.shared.isBusy else {
            NSSound.beep()   // an import is running behind its modal sheet: nothing may change under it
            return
        }
        PlaylistSearcher.shared.prepare()

        let model = SearchModel()
        model.onChoose = { [weak self] in self?.choose($0, $1) }
        let hosting = NSHostingView(rootView: SearchView(
            model: model,
            onCancel: { [weak self] in self?.close() },
            onRowsChange: { [weak self] in self?.resize(rows: $0) }
        ))
        hosting.sizingOptions = []

        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Layout.searchWidth, height: Layout.searchHeight(rows: 0)),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        place(panel)
        self.panel = panel

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func choose(_ result: SearchResult, _ action: SearchAction) {
        switch action {
        case .play: play(result)
        case .goTo: goTo(result)
        case .enqueue: enqueue(result)
        }
    }

    /// Adds a track, or all tracks of an album, to the queue. The window stays open (the result line shows where the
    /// track is in the queue now), so more can be added; a playlist can't be queued.
    private func enqueue(_ result: SearchResult) {
        let playback = PlaybackState.shared
        guard playback.queue.isEnabled, let id = result.trackID,
              let playlist = PlaylistStore.shared.playlist(named: result.playlist),
              let pos = playlist.position(of: id) else { return }
        let tracks: [Track]
        switch result.kind {
        case .track: tracks = [playlist.albums[pos.album].tracks[pos.track]]
        case .album: tracks = playlist.albums[pos.album].tracks
        case .playlist: return
        }
        playback.enqueue(tracks.map { QueueEntry(playlist: result.playlist, id: $0.id) })
    }

    /// Opens the result's playlist with the result selected, and brings the main window forward (also from the
    /// background or the Dock).
    private func goTo(_ result: SearchResult) {
        close()
        switch result.kind {
        case .track, .album:
            guard let id = result.trackID else { return }
            PlaylistStore.shared.reveal(trackID: id, inPlaylist: result.playlist, wholeAlbum: result.kind == .album)
        case .playlist:
            PlaylistStore.shared.setActive(result.playlist)
        }
        NSApp.activate()
        if let window = Dialogs.hostWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func play(_ result: SearchResult) {
        close()
        let playback = PlaybackState.shared
        switch result.kind {
        case .track:
            guard let id = result.trackID else { return }
            playback.play(trackID: id, inPlaylist: result.playlist)
        case .album:
            guard let id = result.trackID else { return }
            playback.play(trackID: id, inPlaylist: result.playlist, wholeAlbum: true)
        case .playlist:
            playback.play(playlist: result.playlist)
        }
    }

    /// Resizes the window to show this many lines under the field, keeping its top edge where it is.
    private func resize(rows: Int) {
        guard let panel else { return }
        let frame = panel.frame
        let height = Layout.searchHeight(rows: rows)
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
    }

    /// Top center of the screen the mouse is on, a bit below the top edge.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let top = area.maxY - area.height * Layout.searchTopOffset
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: top - size.height))
    }

    /// A borderless panel that can take the keyboard focus (they can't by default).
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}
