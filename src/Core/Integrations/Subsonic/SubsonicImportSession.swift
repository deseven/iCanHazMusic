// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// One "add Subsonic tracks to the playlist" run, the counterpart of `ImportSession` for the tracks of a server: get the
/// albums (a playlist of the server has to be read first). The songs themselves are downloaded when they play (or by
/// `SubsonicAutoDownloads`), and the covers are fetched when something shows them (`SubsonicCovers`). The stage is
/// published for the sheet that is shown meanwhile, which calls `abort()`. Foundation only.
///
/// What is added to the playlist is up to the caller (`ImportCoordinator`): an aborted run yields no albums.
@MainActor
@Observable
final class SubsonicImportSession {
    enum Stage {
        case loading       // the albums are read from the server
        case appending     // the caller adds the albums to the playlist
    }

    struct Outcome {
        /// Albums in playlist order, ready to be appended; empty if aborted or failed.
        let albums: [Album]
        let aborted: Bool
        /// Why the run couldn't go on, as a sentence.
        let error: String?
    }

    private(set) var stage = Stage.loading
    private(set) var isAborting = false

    @ObservationIgnored private var task: Task<Outcome, Never>?

    /// The albums are complete, only the playlist is being put together: too late to abort.
    var isFinishing: Bool { stage == .appending }

    func abort() {
        guard !isAborting, !isFinishing else { return }
        isAborting = true
        task?.cancel()
    }

    func beginAppending() {
        stage = .appending
    }

    /// Gets the albums from `makeAlbums`.
    func run(albums makeAlbums: @escaping @MainActor () async throws -> [Album]) async -> Outcome {
        let task = Task { () -> Outcome in
            let albums: [Album]
            do {
                albums = try await makeAlbums()
            } catch is CancellationError {
                return Outcome(albums: [], aborted: true, error: nil)
            } catch {
                let text = (error as? SubsonicError)?.message ?? error.localizedDescription
                return Outcome(albums: [], aborted: false, error: SubsonicService.sentence(text))
            }
            guard !Task.isCancelled else { return Outcome(albums: [], aborted: true, error: nil) }

            Log.info("subsonic: \(albums.count) album(s) ready")
            return Outcome(albums: albums, aborted: false, error: nil)
        }
        self.task = task
        let outcome = await task.value
        self.task = nil
        return outcome
    }
}
