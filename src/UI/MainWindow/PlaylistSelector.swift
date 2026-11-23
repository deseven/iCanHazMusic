// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The list of playlists (a side panel of `PlayerArea`). The one playback runs from is marked with a dot. With the queue
/// turned on, its item comes first, apart from the playlists by a separator. The rows are styled like a sidebar's, but
/// the background is the window's, like the now playing block's.
///
/// With a Subsonic connection enabled the playlists are in sections: "Local Playlists" first, then one per connection
/// (its playlists as the server has them), each with a button of its own to make a playlist there. Without one it is a
/// single list with the button at the bottom. A playlist of a server that is downloaded automatically shows how far that
/// is (`AutoDownloadMark`) until it is all there.
///
/// The "sections" are not `Section`s but a header row (`SectionHeader`, not selectable) followed by the playlists, on
/// purpose: a sidebar list puts a collapse/expand button on the hover of a real section header (and
/// `.collapsible(false)` doesn't remove it), where the plus button is.
struct PlaylistSelector: View {
    private let store = PlaylistStore.shared
    private let playback = PlaybackState.shared
    private let remote = SubsonicPlaylists.shared

    /// What a row of the list stands for. The queue isn't a playlist (and no playlist name can be mistaken for it).
    private enum Item: Hashable {
        case queue
        case playlist(PlaylistID)
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
            if store.remoteSections.isEmpty {
                ForEach(store.names, id: \.self) { name in
                    row(.local(name), title: name, isLocked: false)
                }
            } else {
                SectionHeader(title: "Local Playlists", connection: nil)
                    .selectionDisabled()
                ForEach(store.names, id: \.self) { name in
                    row(.local(name), title: name, isLocked: false)
                }
                ForEach(store.remoteSections, id: \.connection) { section in
                    SectionHeader(title: section.name, connection: section.connection)
                        .padding(.top, 8)
                        .selectionDisabled()
                    ForEach(section.playlists, id: \.id) { info in
                        row(.remote(connection: section.connection, id: info.id), title: info.name,
                            isLocked: !info.isOwnEditable)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.remoteSections.isEmpty {
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
    }

    private func row(_ id: PlaylistID, title: String, isLocked: Bool) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: "music.note.list")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(isSelected(id) ? Color.white : Color.secondary)
                    .help("Read-only: \(remote.readOnlyReason(id) ?? "it can't be changed")")
            }
            if id.isRemote {
                AutoDownloadMark(id: id, isSelected: isSelected(id))
            }
            if id == store.playingID {
                // Playback runs from this playlist (playing or paused). The selected row is filled with the
                // accent color itself, so the dot is white there.
                Circle()
                    .fill(isSelected(id) ? Color.white : Color.accentColor)
                    .frame(width: 8, height: 8)
                    .help("Playing from this playlist")
            }
        }
        .tag(Item.playlist(id))
        .contextMenu {
            Button("Rename") {
                Task { await PlaylistActions.rename(id) }
            }
            .disabled(!store.canEdit(id))
            Button("Delete") {
                Task { await PlaylistActions.delete(id) }
            }
            .disabled(!store.canEdit(id))
            if id.isRemote {
                Divider()
                Toggle("Download All Tracks Automatically", isOn: Binding(
                    get: { SubsonicAutoDownloads.shared.isEnabled(id) },
                    set: { enabled in Task { await PlaylistActions.setAutoDownload(enabled, for: id) } }
                ))
            }
        }
    }

    /// The queue is what's shown (and chosen in the list) while it is on and its view is open.
    private var showsQueue: Bool { store.isQueueShown && playback.queue.isEnabled }

    private func isSelected(_ id: PlaylistID) -> Bool {
        !showsQueue && id == store.activeID
    }

    private var selection: Binding<Item?> {
        Binding(
            get: { showsQueue ? .queue : .playlist(store.activeID) },
            set: {
                switch $0 {
                case .queue: store.showQueue()
                case .playlist(let id): store.setActive(id)
                case nil: break
                }
            }
        )
    }
}

/// The row that opens a section: its title with the button that makes a playlist in it. `connection`: the server's
/// (nil: this Mac's), whose section also shows when it can't be reached.
private struct SectionHeader: View {
    let title: String
    let connection: UUID?
    private let remote = SubsonicPlaylists.shared

    var body: some View {
        let state = connection.map { remote.state(of: $0) }
        HStack(spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let state, !state.isOnline, let error = state.error {
                Image(systemName: "wifi.slash")
                    .help("The server can't be reached, its playlists can be played but not changed: \(error)")
            }
            Spacer(minLength: 0)
            Button {
                Task { await PlaylistActions.create(on: connection) }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(state.map { !$0.isOnline } ?? false)
            .help(state.map { $0.isOnline ? "New playlist on \(title)" : "The server can't be reached" } ?? "New local playlist")
        }
    }
}

/// How far downloading a playlist of a server that is downloaded automatically is: a small bar until every track is
/// there. Nothing for a playlist that isn't downloaded automatically, is complete (or wasn't looked at yet). A view of
/// its own, so that the progress of a download redraws only this.
private struct AutoDownloadMark: View {
    let id: PlaylistID
    let isSelected: Bool
    private let downloads = SubsonicAutoDownloads.shared

    var body: some View {
        if downloads.isEnabled(id), let progress = downloads.progress[id], !progress.isComplete {
            ProgressView(value: Double(progress.downloaded), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(isSelected ? Color.white : nil)
                .frame(width: Layout.autoDownloadProgressWidth)
                .help(help(progress))
        }
    }

    private func help(_ progress: SubsonicAutoDownloads.Progress) -> String {
        let count = "\(progress.downloaded) of \(progress.total) track(s) downloaded"
        if let connection = id.connection, downloads.downloading.contains(connection) { return "Downloading: \(count)" }
        return "\(count), the rest is downloaded when the server can be reached"
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
