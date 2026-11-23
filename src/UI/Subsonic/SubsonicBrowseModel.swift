// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// What the "Add from Subsonic" sheet shows and does: the artists of the connection (the one of the playlist the tracks go
/// to), then the artist's albums, optionally one album, and the tracks of that artist or album to pick from (all picked
/// to begin with).
///
/// - The artists of the connection are loaded at once; picking an artist loads all its albums with their songs (one call
///   for the albums and one per album, a few at a time), so choosing an album afterwards only filters what is there.
/// - Whatever is picked in a list clears everything that depends on it. A load that is overtaken by another pick is
///   cancelled and its answer is never shown.
/// - What goes wrong is a line of text in the list that was being loaded (`LoadState.failed`), not an alert.
@MainActor
@Observable
final class SubsonicBrowseModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// The connection the tracks are taken from.
    let connectionID: UUID

    private(set) var artists: [SubsonicArtist] = []
    private(set) var artistsState = LoadState.idle
    /// Narrows the artist list.
    var artistFilter = ""
    private(set) var artistID: String?

    /// The albums of the picked artist with their songs, the oldest album first.
    private(set) var contents: [SubsonicAlbumContent] = []
    private(set) var contentsState = LoadState.idle
    /// How many albums of the artist are loaded, of how many; nil when nothing is loading.
    private(set) var progress: (done: Int, total: Int)?
    /// The picked album; nil: all albums of the artist.
    private(set) var albumID: String?

    /// The songs that are ticked.
    private(set) var selectedSongIDs = Set<String>()

    @ObservationIgnored private let service: SubsonicService
    @ObservationIgnored private var artistsTask: Task<Void, Never>?
    @ObservationIgnored private var contentsTask: Task<Void, Never>?

    init(service: SubsonicService, connection: UUID) {
        self.service = service
        connectionID = connection
        loadArtists()
    }

    deinit {
        artistsTask?.cancel()
        contentsTask?.cancel()
    }

    // MARK: - What is shown

    /// The artists that match the filter.
    var visibleArtists: [SubsonicArtist] {
        let filter = artistFilter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return artists }
        return artists.filter { $0.name.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The songs the track list shows: those of the picked album, or of all albums.
    var picks: [SubsonicPick] {
        contents.filter { albumID == nil || $0.album.id == albumID }
            .flatMap { content in content.songs.map { SubsonicPick(album: content.album, song: $0) } }
    }

    var selectedPicks: [SubsonicPick] {
        picks.filter { selectedSongIDs.contains($0.song.id) }
    }

    var totalSongCount: Int { contents.reduce(0) { $0 + $1.songs.count } }

    var canAdd: Bool { !selectedPicks.isEmpty }

    /// What the sheet hands back: nil if there is nothing to add.
    var outcome: SubsonicBrowseOutcome? {
        guard canAdd else { return nil }
        return SubsonicBrowseOutcome(connection: connectionID, picks: selectedPicks)
    }

    // MARK: - Picking

    func selectArtist(_ id: String) {
        guard artistID != id else { return }
        artistID = id
        albumID = nil
        contents = []
        selectedSongIDs = []
        loadContents()
    }

    /// `nil`: all albums of the artist.
    func selectAlbum(_ id: String?) {
        guard albumID != id else { return }
        albumID = id
        selectAll()
    }

    // MARK: - Ticking

    func isSelected(_ songID: String) -> Bool {
        selectedSongIDs.contains(songID)
    }

    func setSelected(_ songID: String, _ on: Bool) {
        if on { selectedSongIDs.insert(songID) } else { selectedSongIDs.remove(songID) }
    }

    func selectAll() {
        selectedSongIDs = Set(picks.map(\.song.id))
    }

    func selectNone() {
        selectedSongIDs = []
    }

    // MARK: - Loading

    private func loadArtists() {
        artistsTask?.cancel()
        let id = connectionID
        guard let connection = service.connection(id) else {
            artistsState = .failed("The connection is switched off.")
            return
        }
        artistsState = .loading
        artistsTask = Task { [weak self] in
            do {
                let artists = try await connection.artists().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                guard let self, !Task.isCancelled, self.connectionID == id else { return }
                self.artists = artists
                self.artistsState = .idle
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.connectionID == id else { return }
                self.artistsState = .failed(Self.text(of: error))
            }
        }
    }

    private func loadContents() {
        contentsTask?.cancel()
        guard let artistID, let connection = service.connection(connectionID) else {
            contentsState = .failed("The connection is switched off.")
            return
        }
        contentsState = .loading
        progress = nil
        contentsTask = Task { [weak self] in
            do {
                let contents = try await connection.albumContents(ofArtist: artistID) { done, total in
                    guard let self, self.artistID == artistID else { return }
                    self.progress = (done, total)
                }
                guard let self, !Task.isCancelled, self.artistID == artistID, self.connectionID == connectionID else { return }
                self.contents = contents
                self.contentsState = .idle
                self.progress = nil
                self.selectAll()
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.artistID == artistID else { return }
                self.contentsState = .failed(Self.text(of: error))
                self.progress = nil
            }
        }
    }

    private static func text(of error: Error) -> String {
        if let error = error as? SubsonicError { return SubsonicService.sentence(error.message) }
        return SubsonicService.sentence(error.localizedDescription)
    }
}
