// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// Who follows the playlists of the servers (`SubsonicAutoDownloads`): `SubsonicPlaylists` tells it whenever what they
/// are or what they have may have changed.
@MainActor
protocol RemotePlaylistWatching: AnyObject {
    /// The playlists of the connection or their content changed, or the server was just looked at. Returns once the
    /// files that are to be kept are known: the files of a gone playlist are deleted after that.
    func playlistsChanged(of connection: UUID) async
    /// Connections were switched on or off (`PlaylistStore.remoteSections` has the ones that are on).
    func connectionsChanged()
}

/// The playlists of the servers that are downloaded automatically ("Download All Tracks Automatically",
/// `RemotePlaylistInfo.autoDownload`): every song of them is downloaded and kept, whatever the cache size of the
/// connection.
///
/// - **Keeping**: the songs of all such playlists of a connection are the pinned files of `SubsonicDownloads`, which never
///   deletes them and doesn't count them towards the cache size. A song that leaves them (its playlist is no longer
///   downloaded automatically, it was removed from the playlist, the playlist is gone) is a cached file like any other
///   from then on. A connection that is switched off keeps its pinned files (the list is saved with the downloads), and
///   nothing is looked at for it until it is switched on again.
/// - **Downloading**: what is missing is downloaded in the background, a few songs at a time, through the same leases as
///   playback (a song that plays meanwhile shares the download). Looked at again whenever the playlists change and after
///   every look at the server (once a minute), which is also when a song that couldn't be had is tried again. A few
///   failures in a row (the server can't be reached) stop it until then.
/// - **Progress**: per playlist, how many of its songs are there (`progress`), for the playlist selector.
@MainActor
@Observable
final class SubsonicAutoDownloads: RemotePlaylistWatching {
    static let shared = SubsonicAutoDownloads(store: .shared, service: .shared, downloads: nil)

    /// How many of a playlist's songs (each counted once) are downloaded.
    struct Progress: Equatable {
        var downloaded: Int
        var total: Int
        var isComplete: Bool { downloaded >= total }
    }

    /// Songs downloaded at the same time, per connection.
    static let concurrency = 2
    /// Failures in a row after which downloading stops until the next look at the server.
    static let maxFailuresInRow = 3

    /// Every playlist that is downloaded automatically (of an enabled connection), once it was looked at.
    private(set) var progress: [PlaylistID: Progress] = [:]
    /// The connections whose songs are being downloaded now.
    private(set) var downloading: Set<UUID> = []

    private struct ConnectionState {
        /// Counts the looks at the playlists: one that was overtaken by a newer one changes nothing.
        var generation = 0
        /// The songs of the connection's playlists that are downloaded automatically (by song ID).
        var wanted: [String: SubsonicRef] = [:]
        /// Of those, the ones whose file is there.
        var present = Set<String>()
        /// What is still to be downloaded, the next one last.
        var queue: [SubsonicRef] = []
        var inFlight = Set<String>()
        /// What couldn't be had since the last look (tried again with the next one).
        var failed = Set<String>()
        var worker: Worker?
    }

    private struct Worker {
        let id: UUID
        let task: Task<Void, Never>
    }

    @ObservationIgnored private let store: PlaylistStore
    @ObservationIgnored private let service: SubsonicService
    @ObservationIgnored private var downloadsInstance: SubsonicDownloads?
    /// The songs (IDs) of each playlist that is downloaded automatically.
    @ObservationIgnored private var songs: [PlaylistID: Set<String>] = [:]
    @ObservationIgnored private var states: [UUID: ConnectionState] = [:]

    /// `downloads`: nil for `SubsonicDownloads.shared` (made when first needed).
    init(store: PlaylistStore, service: SubsonicService, downloads: SubsonicDownloads?) {
        self.store = store
        self.service = service
        downloadsInstance = downloads
    }

    private var downloads: SubsonicDownloads {
        if let downloadsInstance { return downloadsInstance }
        let shared = SubsonicDownloads.shared
        downloadsInstance = shared
        return shared
    }

    // MARK: - The setting

    func isEnabled(_ id: PlaylistID) -> Bool {
        store.remoteInfo(id)?.autoDownload == true
    }

    /// Turns downloading all songs of a playlist of a server on or off. Returns once what is to be kept is known (the
    /// downloads go on in the background).
    func setEnabled(_ enabled: Bool, for id: PlaylistID) async {
        guard let connection = id.connection, let info = store.remoteInfo(id), info.autoDownload != enabled else { return }
        store.updateRemoteInfo(id) { $0.autoDownload = enabled }
        Log.info("subsonic[\(service.displayName(of: connection))]: '\(info.name)' is "
            + (enabled ? "downloaded automatically now" : "no longer downloaded automatically"))
        await playlistsChanged(of: connection)
    }

    // MARK: - RemotePlaylistWatching

    func connectionsChanged() {
        let enabled = Set(store.remoteSections.map(\.connection))
        for connection in states.keys where !enabled.contains(connection) {
            stopWorker(connection)
            states[connection] = nil
        }
        songs = songs.filter { $0.key.connection.map(enabled.contains) ?? false }
        let kept = progress.filter { $0.key.connection.map(enabled.contains) ?? false }
        if kept != progress { progress = kept }
        for connection in enabled {
            Task { await playlistsChanged(of: connection) }
        }
    }

    func playlistsChanged(of connection: UUID) async {
        // A connection that is off: its playlists aren't known now, so what is pinned stays as it is.
        guard isShown(connection) else { return }
        states[connection, default: ConnectionState()].generation += 1
        guard let generation = states[connection]?.generation else { return }

        let ids = store.remotePlaylists(of: connection).filter(\.autoDownload).map { PlaylistID.remote(connection: connection, id: $0.id) }
        var contents: [PlaylistID: [SubsonicRef]] = [:]
        for id in ids {
            guard let playlist = await store.readPlaylist(id) else { continue }
            contents[id] = playlist.albums.flatMap { $0.tracks.compactMap(\.subsonic) }
        }
        guard states[connection]?.generation == generation, isShown(connection) else { return }   // overtaken

        // In the order of the playlists, each song once.
        var wanted: [String: SubsonicRef] = [:]
        var ordered: [SubsonicRef] = []
        for id in ids {
            for ref in contents[id] ?? [] where ref.connection == connection && wanted[ref.songID] == nil {
                wanted[ref.songID] = ref
                ordered.append(ref)
            }
        }
        let playlistSongs = contents.mapValues { Set($0.map(\.songID)) }
        let unchanged = states[connection].map { state in
            state.wanted == wanted && state.queue.isEmpty && state.failed.isEmpty
        } ?? false
        if unchanged, songs.filter({ $0.key.connection == connection }) == playlistSongs { return }   // nothing to do

        let downloads = self.downloads
        downloads.setPinnedSongs(ordered, of: connection)
        let present = await Task.detached(priority: .utility) { downloads.downloadedSongs(ordered) }.value
        guard states[connection]?.generation == generation, isShown(connection), var state = states[connection] else { return }

        state.wanted = wanted
        state.present = present
        state.failed = []
        state.queue = ordered.reversed().filter { !present.contains($0.songID) && !state.inFlight.contains($0.songID) }
        states[connection] = state
        songs = songs.filter { $0.key.connection != connection }.merging(playlistSongs) { $1 }
        updateProgress(of: connection)

        if wanted.isEmpty {
            stopWorker(connection)
        } else {
            startWorker(connection)
        }
    }

    // MARK: - Downloading

    private func isShown(_ connection: UUID) -> Bool {
        store.remoteSections.contains { $0.connection == connection }
    }

    private func startWorker(_ connection: UUID) {
        guard let state = states[connection], state.worker == nil, !state.queue.isEmpty,
              service.connection(connection) != nil else { return }
        let token = UUID()
        let downloads = self.downloads
        let task = Task { [weak self] () -> Void in await self?.work(connection, token: token, downloads: downloads) }
        states[connection]?.worker = Worker(id: token, task: task)
        downloading.insert(connection)
        Log.info("subsonic[\(service.displayName(of: connection))]: downloading \(state.queue.count) song(s) of the playlists that are downloaded automatically")
    }

    private func stopWorker(_ connection: UUID) {
        states[connection]?.worker?.task.cancel()
        states[connection]?.worker = nil
        states[connection]?.queue = []
        downloading.remove(connection)
    }

    private func work(_ connection: UUID, token: UUID, downloads: SubsonicDownloads) async {
        var done = 0
        var failed = 0
        var failuresInRow = 0
        await withTaskGroup(of: (song: String, ok: Bool).self) { group in
            var running = 0
            while true {
                while running < Self.concurrency, failuresInRow < Self.maxFailuresInRow, !Task.isCancelled,
                      let ref = nextSong(of: connection) {
                    running += 1
                    let url = ref.url
                    let song = ref.songID
                    group.addTask {
                        let lease = downloads.acquire(url)
                        do {
                            _ = try await lease.file()
                            return (song, true)
                        } catch {
                            return (song, false)
                        }
                    }   // the lease goes with the task: the file stays, it is pinned
                }
                guard let result = await group.next() else { break }
                running -= 1
                states[connection]?.inFlight.remove(result.song)
                if result.ok {
                    done += 1
                    failuresInRow = 0
                    states[connection]?.present.insert(result.song)
                    updateProgress(of: connection)
                } else if !Task.isCancelled {
                    failed += 1
                    failuresInRow += 1
                    states[connection]?.failed.insert(result.song)
                }
            }
        }

        guard states[connection]?.worker?.id == token else { return }   // stopped
        states[connection]?.worker = nil
        downloading.remove(connection)
        let name = service.displayName(of: connection)
        if failuresInRow >= Self.maxFailuresInRow {
            Log.error("subsonic[\(name)]: automatic downloads stopped after \(failuresInRow) failures in a row (\(done) song(s) downloaded); the rest is tried again with the next look at the server")
            return
        }
        Log.info("subsonic[\(name)]: automatic downloads done, \(done) song(s) downloaded" + (failed > 0 ? ", \(failed) couldn't be had (tried again with the next look at the server)" : ""))
        startWorker(connection)   // what came in meanwhile
    }

    /// The next song to download: still wanted, not there, not on its way.
    private func nextSong(of connection: UUID) -> SubsonicRef? {
        while let ref = states[connection]?.queue.popLast() {
            guard let state = states[connection], state.wanted[ref.songID] != nil, !state.present.contains(ref.songID),
                  !state.inFlight.contains(ref.songID), !state.failed.contains(ref.songID) else { continue }
            states[connection]?.inFlight.insert(ref.songID)
            return ref
        }
        return nil
    }

    private func updateProgress(of connection: UUID) {
        let present = states[connection]?.present ?? []
        var updated = progress.filter { $0.key.connection != connection }
        for (id, set) in songs where id.connection == connection {
            updated[id] = Progress(downloaded: set.intersection(present).count, total: set.count)
        }
        if updated != progress { progress = updated }
    }
}
