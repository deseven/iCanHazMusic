import Foundation
import Observation

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

    /// A result was chosen (Return, click).
    @ObservationIgnored var onChoose: (SearchResult) -> Void = { _ in }

    @ObservationIgnored private let searcher: PlaylistSearcher
    @ObservationIgnored private let store: PlaylistStore
    @ObservationIgnored private var running = false
    @ObservationIgnored private var queryChangedWhileRunning = false
    @ObservationIgnored private var chooseWhenCurrent = false

    init(searcher: PlaylistSearcher? = nil, store: PlaylistStore? = nil) {
        self.searcher = searcher ?? .shared
        self.store = store ?? .shared
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
    func choose() {
        guard isCurrent else {
            chooseWhenCurrent = true
            return
        }
        guard results.indices.contains(selected) else { return }
        onChoose(results[selected])
    }

    func choose(_ index: Int) {
        guard results.indices.contains(index) else { return }
        onChoose(results[index])
    }

    // MARK: Searching

    private func queryChanged() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
            selected = 0
            isCurrent = true
            queryChangedWhileRunning = running   // what a running search finds is of no use
            chooseWhenCurrent = false
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
                    if chooseWhenCurrent {
                        chooseWhenCurrent = false
                        choose()
                    }
                }
            } while queryChangedWhileRunning
            running = false
        }
    }
}
