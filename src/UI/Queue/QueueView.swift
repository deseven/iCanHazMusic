import SwiftUI

/// The queue, shown in place of a playlist when its item is chosen in the sidebar: a flat list of the queued tracks,
/// `place  Artist – Title  duration  [playlist]`, in the order they play. Entries can be removed, nothing else is
/// done with them (see `VirtualPlaylistView`, which does the list).
struct QueueView: View {
    private let playback = PlaybackState.shared
    private let store = PlaylistStore.shared

    @State private var selection: Set<Int> = []
    @State private var cursor: Int?
    @State private var revealRow: Int?

    var body: some View {
        let shown = Self.rows(of: playback.queue.entries, in: store)
        VirtualPlaylistView(playlist: Self.playlist(of: shown), selection: $selection, cursor: $cursor,
                            revealRow: $revealRow, playingRow: nil, cursorFollowsPlayback: false,
                            showAlbumArt: false, queue: shown.map(\.entry),
                            showsQueuePlaylists: store.names.count > 1) { _ in }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if shown.isEmpty { EmptyQueuePlaceholder() }
            }
            .onChange(of: playback.queue.entries) { old, new in
                // Rows shift when a track starts or entries are removed: what was selected stays selected.
                let selected = Set(selection.compactMap { old.indices.contains($0) ? old[$0] : nil })
                selection = Set(new.indices.filter { selected.contains(new[$0]) })
                cursor = cursor.flatMap { old.indices.contains($0) ? new.firstIndex(of: old[$0]) : nil }
            }
    }

    /// The queued tracks that are still in their playlists, with what is known about them.
    private static func rows(of entries: [QueueEntry], in store: PlaylistStore) -> [(entry: QueueEntry, track: Track)] {
        entries.compactMap { entry in
            store.playlist(named: entry.playlist)?.track(id: entry.id).map { (entry, $0) }
        }
    }

    /// A flat playlist with one track per entry, so that a row is a place in the queue. The tracks get their
    /// place as ID (IDs of different playlists could collide).
    private static func playlist(of rows: [(entry: QueueEntry, track: Track)]) -> Playlist {
        let albums = rows.enumerated().map { index, row in
            let track = Track(id: index + 1, url: row.track.url, number: nil, title: row.track.title,
                              artist: row.track.artist, duration: row.track.duration, codec: row.track.codec)
            return Album(directory: row.track.url.deletingLastPathComponent(), artist: row.track.artist, title: "",
                         year: nil, hasMultipleArtists: false, tracks: [track])
        }
        return Playlist(albums: albums, isFlat: true)
    }
}

/// Shown in the middle of the queue while it has no tracks. It doesn't take clicks.
private struct EmptyQueuePlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet")
                .font(.system(size: 40, weight: .light))
            Text("The queue is empty")
                .font(.title3.weight(.semibold))
            Text("Select tracks or albums in a playlist and press Space (or choose Enqueue from the context menu) to "
                + "add them here. Queued tracks play one after another, then playback goes on in the playlist.")
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 360)
        .padding()
        .allowsHitTesting(false)
    }
}
