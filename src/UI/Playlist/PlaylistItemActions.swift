import AppKit

/// What the context menu and the keys of the playlist do with the selected rows. Everything works on the active
/// playlist as it is when the action runs.
@MainActor
enum PlaylistItemActions {
    private static var store: PlaylistStore { .shared }

    /// Shows the files in Finder (selected together in one window); the directory of an album is opened.
    /// A track whose album header is selected too is covered by that.
    static func reveal(_ selection: Set<Int>) {
        let playlist = store.activePlaylist
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
        let removed = store.activePlaylist.entryIndices(selection)
        await store.remove(entries: removed, from: store.activeName)
    }
}
