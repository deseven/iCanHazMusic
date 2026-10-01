import SwiftUI

/// Shows the active playlist. Switching playlists rebuilds the content view, which gives
/// fresh scroll and selection state.
struct PlaylistView: View {
    private let store = PlaylistStore.shared

    var body: some View {
        PlaylistContentView(name: store.activeName)
            .id(store.activeName)
    }
}

private struct PlaylistContentView: View {
    // TODO: replace the mock with the real playlist content once playlists can be populated.
    @State private var playlist: Playlist
    @State private var selection: Set<Int> = []

    init(name: String) {
        _playlist = State(initialValue: MockPlaylist.make(for: name))
    }

    var body: some View {
        VirtualPlaylistView(playlist: playlist, selection: $selection)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
