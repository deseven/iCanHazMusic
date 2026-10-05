import AppKit

/// What the context menu and the keys of the playlist do with the selected rows. Everything works on the active
/// playlist as it is when the action runs.
@MainActor
enum PlaylistItemActions {
    private static var store: PlaylistStore { .shared }

    /// Shows the files in Finder (selected together in one window); the directory of an album is opened.
    /// A track whose album header is selected too is covered by that.
    static func reveal(_ selection: Set<Int>, in shown: Playlist? = nil) {
        let playlist = shown ?? store.activePlaylist
        let rows = selection.sorted().filter { playlist.rows.indices.contains($0) }
        let albums = Set(rows.compactMap { playlist.rows[$0].isHeader ? playlist.rows[$0].albumIndex : nil })

        var files: [URL] = []
        var directories: [URL] = []
        for id in rows {
            let row = playlist.rows[id]
            if row.isHeader {
                directories.append(playlist.albums[row.albumIndex].directory)
            } else if !albums.contains(row.albumIndex), let track = playlist.track(for: row) {
                files.append(track.url)
            }
        }
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
        for directory in directories { NSWorkspace.shared.open(directory) }
    }

    /// Reads the tags of the selected tracks (of all tracks of selected albums) again, behind the import sheet.
    static func reloadTags(_ selection: Set<Int>) async {
        let playlist = store.activePlaylist
        var seen = Set<URL>()
        let urls = playlist.expandedTrackRows(selection).compactMap { playlist.track(for: playlist.rows[$0])?.url }
            .filter { seen.insert($0).inserted }
        await ImportCoordinator.shared.reloadTags(of: urls)
    }

    /// Takes the selected tracks (all tracks of selected albums) out of the playlist. Playback stops if it was
    /// playing one of them.
    static func remove(_ selection: Set<Int>) async {
        let removed = store.activePlaylist.trackIDs(selection)
        await store.remove(ids: removed, from: store.activeName)
    }

    // MARK: Queue

    /// What the queue key and menu item do with a selection.
    enum QueueToggle {
        /// Add these (the ones of the selection that aren't queued yet).
        case enqueue([QueueEntry])
        /// All of them are queued: take them out.
        case remove(Set<QueueEntry>)
        /// Nothing that can be queued (only the playing track).
        case unavailable

        var title: String {
            if case .remove = self { return "Remove from Queue" }
            return "Enqueue"
        }

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    /// The tracks of a selection of the active playlist (all tracks of selected albums), except the playing one,
    /// which can't be queued.
    static func queueToggle(for selection: Set<Int>) -> QueueToggle {
        let playback = PlaybackState.shared
        let playlist = store.activePlaylist
        let name = store.activeName
        let playing = playback.playingEntry
        let entries = playlist.expandedTrackRows(selection)
            .compactMap { playlist.track(for: playlist.rows[$0])?.id }
            .map { QueueEntry(playlist: name, id: $0) }
            .filter { $0 != playing }
        guard !entries.isEmpty else { return .unavailable }
        let missing = entries.filter { !playback.queue.contains($0) }
        return missing.isEmpty ? .remove(Set(entries)) : .enqueue(missing)
    }

    /// Adds the selection to the queue, or removes it from there if it is all queued already.
    static func toggleQueue(_ selection: Set<Int>) {
        let playback = PlaybackState.shared
        guard playback.queue.isEnabled, !store.isLoading else { return }
        switch queueToggle(for: selection) {
        case .enqueue(let entries): playback.enqueue(entries)
        case .remove(let entries): playback.dequeue(entries)
        case .unavailable: break
        }
    }
}
