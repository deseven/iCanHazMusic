import SwiftUI

/// Shows the active playlist (empty while it's loading). Switching playlists rebuilds the content view,
/// which gives fresh scroll state; the selection and cursor live in the parent (the play button and
/// playback need them).
struct PlaylistView: View {
    @Binding var selection: Set<Int>
    @Binding var cursor: Int?
    @Binding var revealRow: Int?
    private let store = PlaylistStore.shared
    private let playback = PlaybackState.shared

    var body: some View {
        PlaylistContentView(playlist: store.activePlaylist, selection: $selection, cursor: $cursor,
                            revealRow: $revealRow, playingRow: playback.playingRow,
                            cursorFollowsPlayback: playback.cursorFollowsPlayback)
            .id(store.activeName)
    }
}

private struct PlaylistContentView: View {
    let playlist: Playlist
    @Binding var selection: Set<Int>
    @Binding var cursor: Int?
    @Binding var revealRow: Int?
    let playingRow: Int?
    let cursorFollowsPlayback: Bool

    var body: some View {
        VirtualPlaylistView(playlist: playlist, selection: $selection, cursor: $cursor, revealRow: $revealRow,
                            playingRow: playingRow, cursorFollowsPlayback: cursorFollowsPlayback) { row in
            PlaybackState.shared.play(row: row)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
