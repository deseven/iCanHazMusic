import SwiftUI

/// Shows the active playlist. Switching playlists rebuilds the content view, which gives
/// fresh scroll and selection state.
struct PlaylistView: View {
    private let store = PlaylistStore.shared

    var body: some View {
        PlaylistContentView(playlist: store.playlist(named: store.activeName))
            .id(store.activeName)
    }
}

private struct PlaylistContentView: View {
    let playlist: Playlist
    @State private var selection: Set<Int> = []

    var body: some View {
        VirtualPlaylistView(playlist: playlist, selection: $selection)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
