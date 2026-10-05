// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

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

/// Covers a playlist while it is being read and scrolled to its row. The spinner only appears if that takes a
/// moment, so a playlist that is ready at once is swapped in without a flash.
struct OpeningCover: View {
    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if showsSpinner {
                ProgressView().controlSize(.regular)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            showsSpinner = true
        }
    }
}

/// Shown in the middle of a playlist without tracks (a new one, or one that was emptied). Only the buttons take
/// clicks; the rest doesn't, and nothing takes drops, so the window's drag and drop works as usual.
private struct EmptyPlaylistPlaceholder: View {
    private let importer = ImportCoordinator.shared

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 40, weight: .light))
                Text("This playlist is empty")
                    .font(.title3.weight(.semibold))
                Text("Time to add some music!")
                    .font(.callout)
            }
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                Button {
                    Task { await importer.addDirectory() }
                } label: {
                    Label("Add Directory...", systemImage: "folder.badge.plus")
                }
                Button {
                    Task { await importer.addFiles() }
                } label: {
                    Label("Add File(s)...", systemImage: "plus")
                }
            }
            .controlSize(.large)
            .disabled(importer.isBusy)

            Text("Or just drop audio files or folders anywhere on this window.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 380)
        .padding()
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
