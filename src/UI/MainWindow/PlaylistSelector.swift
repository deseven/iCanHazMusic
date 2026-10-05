// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The list of playlists. The one playback runs from is marked with a dot. With the queue turned on, its item comes
/// first, apart from the playlists by a separator.
struct PlaylistSelector: View {
    private let store = PlaylistStore.shared
    private let playback = PlaybackState.shared

    /// What a row of the list stands for. The queue isn't a playlist (and no playlist name can be mistaken for it).
    private enum Item: Hashable {
        case queue
        case playlist(String)
    }

    var body: some View {
        List(selection: selection) {
            if playback.queue.isEnabled {
                QueueRow(count: playback.queue.count)
                    .tag(Item.queue)
                    .contextMenu {
                        Button("Clear Queue") { playback.clearQueue() }
                            .disabled(playback.queue.isEmpty)
                    }
                Divider()
                    .padding(.vertical, 2)
                    .selectionDisabled()
            }
            ForEach(store.names, id: \.self) { name in
                HStack(spacing: 6) {
                    Label(name, systemImage: "music.note.list")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if name == store.playingName {
                        // Playback runs from this playlist (playing or paused). The selected row is filled with the
                        // accent color itself, so the dot is white there.
                        Circle()
                            .fill(isSelected(name) ? Color.white : Color.accentColor)
                            .frame(width: 8, height: 8)
                            .help("Playing from this playlist")
                    }
                }
                .tag(Item.playlist(name))
                .contextMenu {
                    Button("Rename") {
                        Task { await PlaylistActions.rename(name) }
                    }
                    Button("Delete") {
                        Task { await PlaylistActions.delete(name) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    Task { await PlaylistActions.create() }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("New playlist")
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    /// The queue is what's shown (and chosen in the list) while it is on and its view is open.
    private var showsQueue: Bool { store.isQueueShown && playback.queue.isEnabled }

    private func isSelected(_ name: String) -> Bool {
        !showsQueue && name == store.activeName
    }

    private var selection: Binding<Item?> {
        Binding(
            get: { showsQueue ? .queue : .playlist(store.activeName) },
            set: {
                switch $0 {
                case .queue: store.showQueue()
                case .playlist(let name): store.setActive(name)
                case nil: break
                }
            }
        )
    }
}

/// The queue's item: its icon and name, and how many tracks are in it.
private struct QueueRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Label("Queue", systemImage: "list.bullet")
                .lineLimit(1)
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
