// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One line of the search results: a track, an album or a playlist.
struct SearchResult: Identifiable, Equatable {
    /// The order is the one results of equal rank come in.
    enum Kind: Int {
        case playlist, album, track
    }

    let kind: Kind
    /// The playlist it is in (or is).
    let playlist: String
    /// The track; for an album its first track. `nil` for a playlist. It is how the result is found again if the
    /// playlist has changed since (positions aren't stable).
    let trackID: TrackID?
    /// Track and album: the artist ("Various Artists" for some albums).
    let artist: String
    /// The title of a track, the name of an album; empty for a playlist.
    let title: String
    /// Album only.
    let year: String?

    var id: String { "\(kind.rawValue)\u{1F}\(playlist)\u{1F}\(trackID ?? 0)" }

    /// What the result line shows next to the kind: the name of a playlist, "Artist – Title" for a track,
    /// "Artist – Album (Year)" for an album.
    var text: String {
        switch kind {
        case .playlist:
            return playlist
        case .track:
            return "\(artist) – \(title)"
        case .album:
            return "\(artist) – \(title)" + (year.map { " (\($0))" } ?? "")
        }
    }
}

/// The text of one playlist prepared for searching (see `SearchText`). Immutable: it belongs to one `Playlist`
/// instance, and a changed playlist needs a new index.
final class SearchIndex: @unchecked Sendable {
    struct TrackText {
        let title: SearchString
        let artist: SearchString
    }

    struct AlbumText {
        let artist: SearchString
        let title: SearchString
        /// The tracks have different artists (else every track's `artist` is the album's, the same text).
        let hasMultipleArtists: Bool
        let tracks: [TrackText]
    }

    let name: String
    let playlist: Playlist
    let albums: [AlbumText]

    init(name: String, playlist: Playlist) {
        self.name = name
        self.playlist = playlist
        albums = playlist.albums.map { album in
            let artist = SearchText.fold(album.artist)
            // Without several artists the tracks' artist is the album's: the same folded text is shared.
            return AlbumText(
                artist: artist,
                title: SearchText.fold(album.title),
                hasMultipleArtists: album.hasMultipleArtists,
                tracks: album.tracks.map {
                    TrackText(title: SearchText.fold($0.title),
                              artist: album.hasMultipleArtists ? SearchText.fold($0.artist) : artist)
                }
            )
        }
    }
}

/// Fuzzy search over the playlists.
///
/// - A **playlist** is found only by its whole name, no fuzzy matching (ignoring case, accents and extra spaces:
///   `test` finds `Test`, `tes` doesn't); only if there is more than one playlist.
/// - An **album** by its artist and title, a **track** by its artist, title and album. Every word of the query has
///   to be found in one of those. Flat playlists have no albums.
/// - A track is left out if its album is in the results and the track's title alone doesn't match the query: it
///   would only be the album once more for each of its tracks.
/// - `SearchOptions` (Preferences > Search) narrow it down: without `playlists` no playlist is a result; without
///   `albums` no album is, and the album's name (and the "Various Artists" of a compilation) isn't searched for the
///   tracks either, only their own artist and title; without `fuzzy` a word has to be a part of the text.
///
/// Order: found playlists come first. Then the entries of the playlist that is playing (else
/// the active one), then those of the others; in each of these groups exact matches come before fuzzy ones, then
/// the better match, then albums before tracks, then the order of the playlists.
enum SearchEngine {
    /// How many results there are at most (all of them are shown, the list doesn't scroll).
    static let defaultLimit = 10

    /// The group of playlist results: before the entries of every playlist.
    private static let playlistGroup = -1

    private struct Candidate {
        let group: Int
        let isExact: Bool
        let score: Int
        let kind: SearchResult.Kind
        let index: Int
        let album: Int
        let track: Int
        let order: Int
    }

    /// `playlistNames`: all playlists, also those that have no index (yet). `preferred`: the playlist whose entries
    /// come first.
    static func search(_ query: String, indexes: [SearchIndex], playlistNames: [String], preferred: String?,
                       options: SearchOptions = SearchOptions(), limit: Int = defaultLimit) -> [SearchResult] {
        let words = SearchText.tokens(of: query)
        guard !words.isEmpty else { return [] }

        var candidates: [Candidate] = []
        var order = 0
        func add(_ match: FieldMatch, group: Int, kind: SearchResult.Kind, index: Int, album: Int = 0, track: Int = 0) {
            candidates.append(Candidate(group: group, isExact: match.isExact, score: match.score, kind: kind,
                                       index: index, album: album, track: track, order: order))
            order += 1
        }

        let fuzzy = options.fuzzy

        if options.playlists, playlistNames.count > 1 {
            let wanted = SearchText.normalized(words)
            for (i, name) in playlistNames.enumerated() where SearchText.normalized(SearchText.tokens(of: name)) == wanted {
                add(FieldMatch(isExact: true, score: 0), group: Self.playlistGroup, kind: .playlist, index: i)
            }
        }

        for (n, index) in indexes.enumerated() {
            let group = index.name == preferred ? 0 : 1
            let isFlat = index.playlist.isFlat
            for (a, album) in index.albums.enumerated() {
                // What each word finds in the album's own fields, which all its tracks share. Without album
                // search an album is neither a result nor a field of its tracks.
                let albumHits = options.albums
                    ? words.map { FuzzyMatcher.best(of: $0, in: [album.artist, album.title], fuzzy: fuzzy) }
                    : []
                var albumFound = false
                if options.albums, !isFlat, let match = FuzzyMatcher.total(albumHits) {
                    add(match, group: group, kind: .album, index: n, album: a)
                    albumFound = true
                }
                for (t, track) in album.tracks.enumerated() {
                    var titleHits: [FieldMatch?] = []
                    var trackHits: [FieldMatch?] = []
                    for (w, word) in words.enumerated() {
                        let own = FuzzyMatcher.best(of: word, in: [track.title], fuzzy: fuzzy)
                        titleHits.append(own)
                        var hit = own
                        if options.albums {
                            hit = FuzzyMatcher.better(hit, albumHits[w])
                            if album.hasMultipleArtists {
                                hit = FuzzyMatcher.better(hit, FuzzyMatcher.best(of: word, in: [track.artist], fuzzy: fuzzy))
                            }
                        } else {
                            hit = FuzzyMatcher.better(hit, FuzzyMatcher.best(of: word, in: [track.artist], fuzzy: fuzzy))
                        }
                        guard hit != nil else { break }
                        trackHits.append(hit)
                    }
                    guard trackHits.count == words.count, let match = FuzzyMatcher.total(trackHits) else { continue }
                    if albumFound, FuzzyMatcher.total(titleHits) == nil { continue }
                    add(match, group: group, kind: .track, index: n, album: a, track: t)
                }
            }
        }

        candidates.sort { x, y in
            if x.group != y.group { return x.group < y.group }
            if x.isExact != y.isExact { return x.isExact }
            if x.score != y.score { return x.score > y.score }
            if x.kind != y.kind { return x.kind.rawValue < y.kind.rawValue }
            return x.order < y.order
        }

        return candidates.prefix(limit).map { candidate in
            switch candidate.kind {
            case .playlist:
                return SearchResult(kind: .playlist, playlist: playlistNames[candidate.index], trackID: nil,
                                    artist: "", title: "", year: nil)
            case .album:
                let index = indexes[candidate.index]
                let album = index.playlist.albums[candidate.album]
                return SearchResult(kind: .album, playlist: index.name, trackID: album.tracks.first?.id,
                                    artist: album.artist, title: album.title, year: album.year)
            case .track:
                let index = indexes[candidate.index]
                let album = index.playlist.albums[candidate.album]
                let track = album.tracks[candidate.track]
                return SearchResult(kind: .track, playlist: index.name, trackID: track.id,
                                    artist: track.artist, title: track.title, year: nil)
            }
        }
    }
}

/// Keeps the search indexes of the playlists in memory (made when first needed, in the background, and again for
/// a playlist whose content has been replaced) and runs searches over them.
@MainActor
final class PlaylistSearcher {
    static let shared = PlaylistSearcher(store: .shared, settings: .shared)

    private struct Entry {
        let playlist: Playlist
        let task: Task<SearchIndex, Never>
    }

    private let store: PlaylistStore
    private let settings: SearchSettings
    private var entries: [String: Entry] = [:]

    /// `settings`: what the searches look at; the default is every kind of result with fuzzy matching.
    init(store: PlaylistStore, settings: SearchSettings? = nil) {
        self.store = store
        self.settings = settings ?? SearchSettings()
    }

    /// Starts making the indexes that are missing or out of date, so the first search doesn't wait for them.
    func prepare() {
        let snapshot = store.loadedPlaylists
        let current = Set(snapshot.map(\.name))
        for name in entries.keys where !current.contains(name) { entries[name] = nil }
        for (name, playlist) in snapshot { _ = index(name: name, playlist: playlist) }
    }

    /// The results for `query` over the playlists that are in memory (the others are found by name only).
    func search(_ query: String, limit: Int = SearchEngine.defaultLimit) async -> [SearchResult] {
        let options = settings.options
        guard !SearchText.tokens(of: query).isEmpty else { return [] }
        prepare()
        var indexes: [SearchIndex] = []
        for (name, playlist) in store.loadedPlaylists {
            indexes.append(await index(name: name, playlist: playlist).value)
        }
        let names = store.names
        let preferred = store.playingName ?? store.activeName
        return await Task.detached(priority: .userInitiated) {
            SearchEngine.search(query, indexes: indexes, playlistNames: names, preferred: preferred, options: options,
                                limit: limit)
        }.value
    }

    private func index(name: String, playlist: Playlist) -> Task<SearchIndex, Never> {
        if let entry = entries[name], entry.playlist === playlist { return entry.task }
        let task = Task.detached(priority: .userInitiated) { SearchIndex(name: name, playlist: playlist) }
        entries[name] = Entry(playlist: playlist, task: task)
        return task
    }
}
