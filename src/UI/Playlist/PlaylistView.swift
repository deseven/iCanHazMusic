import SwiftUI

/// Shows the active playlist (empty while it's loading). Switching playlists rebuilds the content view,
/// which gives fresh scroll state; the selection lives in the parent (the play button needs it).
struct PlaylistView: View {
    @Binding var selection: Set<Int>
    private let store = PlaylistStore.shared

    var body: some View {
        PlaylistContentView(playlist: store.activePlaylist, selection: $selection)
            .id(store.activeName)
    }
}

private struct PlaylistContentView: View {
    let playlist: Playlist
    @Binding var selection: Set<Int>

    var body: some View {
        VirtualPlaylistView(playlist: playlist, selection: $selection) { row in
            PlaybackState.shared.play(row: row)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
