// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// What is done with the chosen result.
enum SearchAction {
    /// Start it. Return and click, or ⇧Return with "Prefer adding to queue".
    case play
    /// ⌥Return: open its playlist and show it in the main window.
    case goTo
    /// Add it to the queue (not there yet). ⇧Return, or Return and click with "Prefer adding to queue".
    case enqueue
}

/// The state of the search window: the query, its results and which one is selected.
@MainActor
@Observable
final class SearchModel {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            queryChanged()
        }
    }

    private(set) var results: [SearchResult] = []
    /// Index into `results`.
    private(set) var selected = 0
    /// The results shown belong to the current query (no search is running or waiting for it).
    private(set) var isCurrent = true

    /// A result was chosen (Return with or without modifiers, click).
    @ObservationIgnored var onChoose: (SearchResult, SearchAction) -> Void = { _, _ in }

    @ObservationIgnored private let searcher: PlaylistSearcher
    @ObservationIgnored private let store: PlaylistStore
    @ObservationIgnored private let settings: SearchSettings
    @ObservationIgnored private let queue: PlaybackQueue
    @ObservationIgnored private var running = false
    @ObservationIgnored private var queryChangedWhileRunning = false
    @ObservationIgnored private var chooseWhenCurrent: SearchAction?

    init(searcher: PlaylistSearcher? = nil, store: PlaylistStore? = nil, settings: SearchSettings? = nil,
         queue: PlaybackQueue? = nil) {
        self.searcher = searcher ?? .shared
        self.store = store ?? .shared
        self.settings = settings ?? .shared
        self.queue = queue ?? PlaybackState.shared.queue
    }

    /// What Return and a click do (and ⇧Return the other way round: they swap places with "Prefer adding to queue").
    /// With the queue turned off, Return plays and that setting has no effect.
    var primaryAction: SearchAction { queue.isEnabled && settings.preferAddingToQueue ? .enqueue : .play }
    /// What ⇧Return does; nothing (`nil`) with the queue turned off.
    var secondaryAction: SearchAction? {
        guard queue.isEnabled else { return nil }
        return settings.preferAddingToQueue ? .play : .enqueue
    }

    /// What the line of a result says about the queue: the place of a queued track (`#2`), "queued" for an album whose
    /// tracks all are. `nil` for the rest.
    func queueMark(for result: SearchResult) -> String? {
        guard queue.isEnabled, !queue.isEmpty, let id = result.trackID,
              let playlist = store.playlist(named: result.playlist) else { return nil }
        switch result.kind {
        case .track:
            return queue.position(of: QueueEntry(playlist: result.playlist, id: id)).map { "#\($0)" }
        case .album:
            guard let pos = playlist.position(of: id) else { return nil }
            let tracks = playlist.albums[pos.album].tracks
            return tracks.allSatisfy { queue.contains(QueueEntry(playlist: result.playlist, id: $0.id)) } ? "queued" : nil
        case .playlist:
            return nil
        }
    }

    /// Results are of different kinds (tracks, albums, playlists), so each line says which. Not when tracks are
    /// the only kind there can be.
    var showsKinds: Bool { !settings.options.tracksOnly }

    /// The hint in the empty field: what can be found.
    var placeholder: String {
        let options = settings.options
        let kinds = ["tracks"] + (options.albums ? ["albums"] : []) + (options.playlists ? ["playlists"] : [])
        return "Search " + (kinds.count == 1 ? kinds[0] : kinds.dropLast().joined(separator: ", ") + " and " + kinds[kinds.count - 1])
    }

    /// Playlists are named in the results only if there is more than one.
    var showsPlaylists: Bool { store.names.count > 1 }

    /// Some playlists haven't been read yet, so the results may be incomplete.
    var isStillLoading: Bool { store.isLoading || store.isPreloading }

    /// The text of the line shown instead of results: nothing for an empty query or while results are on their way.
    var message: String? {
        guard results.isEmpty, isCurrent, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return isStillLoading ? "No results so far, the playlists are still loading…" : "No results"
    }

    /// The number of lines under the field (a message is one).
    var rows: Int {
        results.isEmpty ? (message == nil ? 0 : 1) : results.count
    }

    func move(by delta: Int) {
        guard !results.isEmpty else { return }
        selected = min(max(selected + delta, 0), results.count - 1)
    }

    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selected = index
    }

    /// Chooses the selected result; if the results are about to change (the query was just typed), the one that
    /// will be selected then.
    func choose(_ action: SearchAction?) {
        guard let action else { return }
        guard isCurrent else {
            chooseWhenCurrent = action
            return
        }
        guard results.indices.contains(selected) else { return }
        onChoose(results[selected], action)
    }

    /// A click: the same as Return.
    func choose(_ index: Int) {
        guard results.indices.contains(index) else { return }
        onChoose(results[index], primaryAction)
    }

    // MARK: Searching

    private func queryChanged() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
            selected = 0
            isCurrent = true
            queryChangedWhileRunning = running   // what a running search finds is of no use
            chooseWhenCurrent = nil
            return
        }
        isCurrent = false
        guard !running else {
            queryChangedWhileRunning = true
            return
        }
        run()
    }

    /// One search at a time; when the query has changed meanwhile, the next one starts with the newest.
    private func run() {
        running = true
        Task {
            repeat {
                queryChangedWhileRunning = false
                let asked = query
                let found = await searcher.search(asked)
                if !queryChangedWhileRunning, asked == query {
                    results = found
                    selected = 0
                    isCurrent = true
                    if let action = chooseWhenCurrent {
                        chooseWhenCurrent = nil
                        choose(action)
                    }
                }
            } while queryChangedWhileRunning
            running = false
        }
    }
}
