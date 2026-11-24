// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The track that was started last in each playlist (`.cache/last_played.json`), which is shown again when the
/// playlist is opened. It is a plain map `{"playlist key": track id}`, the key being `PlaylistStore`'s key of the
/// playlist.
///
/// It is kept out of the playlist files on purpose: those are rewritten whole on every save, and a track change
/// is not a reason to do that. A change here is written (this small file only) after `saveDelay`, and at quit
/// (`flush`). Being in the cache, it can be deleted at any time: the playlists then open without a remembered track.
@MainActor
final class LastPlayedStore {
    nonisolated static let defaultSaveDelay: Duration = .seconds(1)

    private let url: URL
    private let saveDelay: Duration
    private var entries: [String: TrackID] = [:]
    private var saveTask: Task<Void, Never>?

    init(url: URL, saveDelay: Duration = LastPlayedStore.defaultSaveDelay) {
        self.url = url
        self.saveDelay = saveDelay
        load()
    }

    /// The last played track of the playlist with this key; setting `nil` forgets it.
    subscript(key: String) -> TrackID? {
        get { entries[key] }
        set {
            guard entries[key] != newValue else { return }
            entries[key] = newValue
            scheduleSave()
        }
    }

    /// Forgets the entries of the playlists that `isKept` doesn't know (deleted behind the app's back, a connection
    /// that was removed).
    func prune(keeping isKept: (String) -> Bool) {
        let stale = entries.keys.filter { !isKept($0) }
        guard !stale.isEmpty else { return }
        for key in stale { entries[key] = nil }
        Log.info("last played: forgot \(stale.count) playlist(s) that don't exist any more")
        scheduleSave()
    }

    /// Writes a pending change right now.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        write()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            entries = try JSONDecoder().decode([String: TrackID].self, from: data)
        } catch {
            Log.error("last played: \(url.lastPathComponent) is not valid (\(error.localizedDescription)), starting empty")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let saveDelay = self.saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.write()
        }
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("last played: can't write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
