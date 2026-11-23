// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// What the sheet hands back when the tracks are added.
struct SubsonicBrowseOutcome {
    let connection: UUID
    let picks: [SubsonicPick]
}

/// The "Add from Subsonic" sheet: the lists of artists and albums of the playlist's server, and below them the tracks
/// of the artist or album, to tick (all are to begin with). See `SubsonicBrowseModel`.
struct SubsonicBrowseSheet: View {
    @Bindable var model: SubsonicBrowseModel
    /// What the tracks are added to: the playlist and its connection.
    let playlistName: String
    let connectionName: String
    /// Called with the picks to add, or nil to cancel.
    let finish: (SubsonicBrowseOutcome?) -> Void

    /// The album list's row for all albums: what the list's selection is while no single album is picked (an album's own
    /// ID is never this).
    private static let allAlbums = "\u{1}all-albums"

    /// A row of the album list; no content: all albums.
    private struct AlbumRow: Identifiable {
        let id: String
        let content: SubsonicAlbumContent?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add from Subsonic")
                    .font(.headline)
                Text("To “\(playlistName)” on \(connectionName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 10) {
                column("Artist", accessory: artistFilter) { artistList }
                column("Album") { albumList }
            }
            .frame(height: Layout.subsonicListsHeight)

            tracksSection
                .frame(height: Layout.subsonicTracksHeight)

            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let outcome = model.outcome { finish(outcome) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdd)
            }
        }
        .padding(20)
        .frame(width: Layout.subsonicBrowseWidth)
    }

    // MARK: - Lists

    private func column<Content: View, Accessory: View>(_ title: String, accessory: Accessory = EmptyView(),
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                accessory
            }
            .frame(height: 20)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private var artistFilter: some View {
        TextField("Filter", text: $model.artistFilter)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .disabled(model.artists.isEmpty)
    }

    private var artistList: some View {
        List(selection: Binding<String?>(get: { model.artistID }, set: { if let id = $0 { model.selectArtist(id) } })) {
            ForEach(model.visibleArtists) { artist in
                Text(artist.name.isEmpty ? TagFallback.artist : artist.name).lineLimit(1).tag(Optional(artist.id))
            }
        }
        .listStyle(.bordered)
        .overlay { artistsOverlay }
    }

    @ViewBuilder
    private var artistsOverlay: some View {
        switch model.artistsState {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            note(message, isError: true)
        case .idle:
            if model.artists.isEmpty {
                note("The server has no artists.")
            } else if model.visibleArtists.isEmpty {
                note("No artist matches.")
            }
        }
    }

    private var albumRows: [AlbumRow] {
        guard !model.contents.isEmpty else { return [] }
        return [AlbumRow(id: Self.allAlbums, content: nil)] + model.contents.map { AlbumRow(id: $0.album.id, content: $0) }
    }

    private var albumList: some View {
        List(selection: Binding<String?>(
            get: { model.albumID ?? Self.allAlbums },
            set: { if let id = $0 { model.selectAlbum(id == Self.allAlbums ? nil : id) } }
        )) {
            ForEach(albumRows) { row in
                if let content = row.content {
                    HStack(spacing: 4) {
                        Text(content.album.name.isEmpty ? TagFallback.album : content.album.name).lineLimit(1)
                        if let year = content.album.year {
                            Text("(\(String(year)))").foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(row.id))
                } else {
                    Text("All albums (\(model.contents.count))")
                        .tag(Optional(row.id))
                }
            }
        }
        .listStyle(.bordered)
        .overlay { albumsOverlay }
    }

    @ViewBuilder
    private var albumsOverlay: some View {
        switch model.contentsState {
        case .loading:
            VStack(spacing: 4) {
                ProgressView().controlSize(.small)
                if let progress = model.progress, progress.total > 0 {
                    Text("Loading albums \(progress.done) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            note(message, isError: true)
        case .idle:
            if model.artistID == nil {
                note("Pick an artist.")
            } else if model.contents.isEmpty {
                note("No albums.")
            }
        }
    }

    // MARK: - Tracks

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Tracks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All") { model.selectAll() }
                    .disabled(model.picks.isEmpty || model.selectedPicks.count == model.picks.count)
                Button("None") { model.selectNone() }
                    .disabled(model.selectedPicks.isEmpty)
            }
            .controlSize(.small)

            List {
                ForEach(model.picks, id: \.song.id) { pick in
                    trackRow(pick)
                }
            }
            .listStyle(.bordered)
            .overlay {
                if model.picks.isEmpty, model.contentsState == .idle {
                    note(model.artistID == nil ? "Pick an artist to see its tracks." : "No tracks.")
                }
            }
        }
    }

    private func trackRow(_ pick: SubsonicPick) -> some View {
        let song = pick.song
        return Toggle(isOn: Binding(get: { model.isSelected(song.id) }, set: { model.setSelected(song.id, $0) })) {
            HStack(spacing: 8) {
                Text(song.track.map { String(format: "%02d", $0) } ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
                Text(song.title.isEmpty ? TagFallback.shownTitle("", file: nil) : song.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if model.albumID == nil {
                    Text(pick.album.name)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
                Text(Self.durationText(song.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Pieces

    private func note(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .padding(8)
    }

    private var summary: String {
        guard model.totalSongCount > 0 else { return "" }
        return "\(model.selectedPicks.count) of \(model.picks.count) tracks selected"
    }

    private static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return "--:--" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
