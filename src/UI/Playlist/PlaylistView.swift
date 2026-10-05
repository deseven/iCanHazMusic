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
                            cursorFollowsPlayback: playback.cursorFollowsPlayback,
                            showAlbumArt: store.displayAlbumArt, name: store.activeName)
            .overlay {
                if !store.isLoading && store.activePlaylist.trackCount == 0 { EmptyPlaylistPlaceholder() }
            }
            .id(store.activeName)
    }
}

/// Shown in the middle of a playlist without tracks (a new one, or one that was emptied). It doesn't take clicks or
/// drops, so the window's drag and drop works as usual.
private struct EmptyPlaylistPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
            Text("This playlist is empty")
                .font(.title3.weight(.semibold))
            Text("Drop audio files or folders onto this window, add them from the File menu, or import an existing playlist from the Playlist menu.")
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 360)
        .padding()
        .allowsHitTesting(false)
    }
}

private struct PlaylistContentView: View {
    let playlist: Playlist
    @Binding var selection: Set<Int>
    @Binding var cursor: Int?
    @Binding var revealRow: Int?
    let playingRow: Int?
    let cursorFollowsPlayback: Bool
    let showAlbumArt: Bool
    let name: String

    var body: some View {
        VirtualPlaylistView(playlist: playlist, selection: $selection, cursor: $cursor, revealRow: $revealRow,
                            playingRow: playingRow, cursorFollowsPlayback: cursorFollowsPlayback,
                            showAlbumArt: showAlbumArt, playlistName: name) { row in
            PlaybackState.shared.play(row: row)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
