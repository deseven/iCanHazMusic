// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// What `SubsonicPlaylists` asks for when a playlist is gone: the downloaded files of its songs deleted.
protocol SubsonicSongFileRemoving: AnyObject {
    /// Deletes the downloaded files of these songs that nothing is using; returns how many.
    @discardableResult
    func removeFiles(ofSongs refs: [SubsonicRef]) -> Int
}

extension SubsonicDownloads: SubsonicSongFileRemoving {}

/// What is known about the way to a server since the app started, for the playlist selector and the read-only notice.
struct SubsonicPlaylistsState: Equatable {
    /// The last call to the server went through.
    var isOnline = false
    /// Why the last one didn't; nil if it did (or there was none yet).
    var error: String?
    var lastSync: Date?
    /// The playlists are being asked for.
    var isBusy = false
}

/// Keeps the playlists of the enabled Subsonic connections in step with their servers, and carries the user's changes to
/// them. The server is what counts: `PlaylistStore` holds a copy (also on disk, so the playlists are there when the server
/// isn't), this makes it match.
///
/// - **Looking at the servers** (`refresh`): once a minute, at launch, when a connection is switched on or the network
///   changes, and when a playlist is opened. One `getPlaylists` says what exists and when each was changed; only the
///   playlists that changed are read (`getPlaylist`). Playlists that are gone from the server are deleted here too (with
///   what was downloaded for them); new ones are added. What was read is merged into the content the app has
///   (`RemotePlaylistMerge`), so the tracks keep their IDs.
/// - **Changing** (`playlistWasEdited`, `append`, `createPlaylist`, `renamePlaylist`, `deletePlaylist`): a removal, a move
///   or turning grouping on is done here first and then sent: the server is given the whole order as it is shown
///   (`createPlaylist` with the ID replaces the songs; it is also the only way to move one), but only if it still has the
///   version the change was made from (`changed`): if somebody else changed it meanwhile the change is dropped and the
///   user told, the playlist shows what the server has. Adding songs, creating, renaming and deleting wait for the server.
/// - **Grouping**: a playlist that is shown grouped by albums is kept in that order on the server too. When what the
///   server has differs from the grouped order (the user turned grouping on, songs were added) and the playlist can be
///   changed, the grouped order is sent (once: if the server doesn't keep it that way it isn't tried again and again).
/// - **Read-only**: a playlist can be changed (`canEdit`) while it is the user's and not marked read-only by the server,
///   the server answered the last time it was asked, and its content is what the server has. Otherwise it plays but
///   doesn't change; `readOnlyReason` says why.
/// - **Watching**: `watcher` (`SubsonicAutoDownloads`) is told whenever the playlists of a connection or their content
///   may have changed, and after every look at the server; the files of gone playlists are deleted only after it has
///   had its say.
@MainActor
@Observable
final class SubsonicPlaylists: RemotePlaylistEditing {
    static let shared = SubsonicPlaylists(store: .shared, service: .shared, files: nil)

    /// How often the servers are looked at.
    static let interval: Duration = .seconds(60)

    private(set) var states: [UUID: SubsonicPlaylistsState] = [:]

    /// Told when something the user did can't be carried to the server (title, message). Set by the UI.
    @ObservationIgnored var onProblem: ((_ title: String, _ message: String) -> Void)?
    /// Told when covers of albums were stored in the cover cache (the views drop what they remember about them).
    @ObservationIgnored var onCoversStored: (() -> Void)?
    /// Follows the playlists (see "Watching" above).
    @ObservationIgnored weak var watcher: RemotePlaylistWatching?

    private struct PendingEdit {
        /// The `changed` of the server's version the edit was made from; nil: not known (the server doesn't say).
        var baseline: String?
        /// There is something to send that wasn't sent yet.
        var dirty: Bool
    }

    private struct Conflict: Error {}

    @ObservationIgnored private let store: PlaylistStore
    @ObservationIgnored private let service: SubsonicService
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var files: SubsonicSongFileRemoving?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var syncing = Set<UUID>()
    /// Counts what changed the set of a connection's playlists here; a listing that was asked for before is out of date.
    @ObservationIgnored private var structureEpoch: [UUID: Int] = [:]
    @ObservationIgnored private var pending: [PlaylistID: PendingEdit] = [:]
    @ObservationIgnored private var pushes: [PlaylistID: Task<Void, Never>] = [:]
    /// The server's order after the grouped order was sent to it, to not try that again for the same result.
    @ObservationIgnored private var rewrites: [PlaylistID: [String]] = [:]
    @ObservationIgnored private var coversRequested = Set<PlaylistID>()
    @ObservationIgnored private var started = false

    /// `files`: what deletes the downloaded files of a gone playlist's songs; nil: `SubsonicDownloads.shared` (made when
    /// first needed).
    init(store: PlaylistStore, service: SubsonicService, files: SubsonicSongFileRemoving?,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.service = service
        self.files = files
        self.sleep = sleep
    }

    /// Makes the store show the playlists of the enabled connections and looks at their servers, now and every minute.
    func start() {
        guard !started else { return }
        started = true
        store.remoteEditor = self
        service.onConnectionsChanged = { [weak self] in self?.connectionsChanged() }
        service.onNetworkChanged = { [weak self] in self?.refreshAll() }
        connectionsChanged()
        let sleep = self.sleep
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(Self.interval) } catch { return }
                guard let self else { return }
                self.refreshAll()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - What is known

    func state(of connection: UUID) -> SubsonicPlaylistsState {
        states[connection] ?? SubsonicPlaylistsState()
    }

    /// Why the playlist can't be changed now, as the end of "Read-only: ..."; nil if it can.
    func readOnlyReason(_ id: PlaylistID) -> String? {
        guard let connection = id.connection, let info = store.remoteInfo(id) else { return nil }
        if info.isForeign { return "owned by \(info.owner ?? "another user")" }
        if info.isReadOnly { return "the server doesn't allow changing it" }
        let state = state(of: connection)
        if !state.isOnline {
            if let error = state.error { return "the server can't be reached (\(error))" }
            return state.isBusy ? "the server is being asked" : "the server hasn't answered yet"
        }
        if info.synced == nil, pending[id] == nil { return "it is being read from the server" }
        return nil
    }

    func canEdit(_ id: PlaylistID) -> Bool {
        guard let connection = id.connection, service.connection(connection) != nil else { return false }
        return readOnlyReason(id) == nil
    }

    // MARK: - Looking at the servers

    private func connectionsChanged() {
        let enabled = service.enabledConnections
        store.setConnections(enabled.map { ($0.id, $0.displayName) })
        watcher?.connectionsChanged()
        let ids = Set(enabled.map(\.id))
        for id in states.keys where !ids.contains(id) { states[id] = nil }
        for id in pending.keys where !(id.connection.map(ids.contains) ?? false) {
            pushes[id]?.cancel()
            pending[id] = nil
            pushes[id] = nil
        }
        refreshAll()
    }

    func refreshAll() {
        for connection in service.enabledConnections {
            let id = connection.id
            Task { await refresh(id) }
        }
    }

    /// Asks the server what playlists there are and reads those that changed. Does nothing for a connection that is
    /// switched off or that is being looked at already.
    func refresh(_ connectionID: UUID) async {
        guard let connection = service.connection(connectionID), syncing.insert(connectionID).inserted else { return }
        states[connectionID, default: SubsonicPlaylistsState()].isBusy = true
        defer {
            syncing.remove(connectionID)
            states[connectionID]?.isBusy = false
        }

        let epoch = structureEpoch[connectionID, default: 0]
        let listed: [SubsonicPlaylist]
        do {
            listed = try await connection.playlists()
        } catch is CancellationError {
            return
        } catch {
            noteFailure(error, of: connectionID)
            return
        }
        noteSuccess(of: connectionID)
        guard structureEpoch[connectionID, default: 0] == epoch, service.connection(connectionID) === connection else {
            return   // the playlists were changed here meanwhile: this listing may not know of that
        }

        let username = service.connections.first { $0.id == connectionID }?.username ?? ""
        let infos = listed.map { Self.info(of: $0, username: username) }
        let listedIDs = Set(infos.map(\.id))
        let gone = store.remotePlaylists(of: connectionID).filter { !listedIDs.contains($0.id) }
        var goneSongs: [SubsonicRef] = []
        for info in gone {
            if let content = await store.readPlaylist(.remote(connection: connectionID, id: info.id)) {
                goneSongs += content.entries.compactMap(\.subsonic)
            }
        }
        guard structureEpoch[connectionID, default: 0] == epoch else { return }
        store.setRemotePlaylists(infos, of: connectionID)
        for info in gone { forgetEdits(of: .remote(connection: connectionID, id: info.id)) }
        if !gone.isEmpty { await watcher?.playlistsChanged(of: connectionID) }   // what it kept may be free now
        if !goneSongs.isEmpty { await removeFiles(of: goneSongs, connection: connectionID) }

        // The one that is shown first.
        let active = store.activeID
        let ids = store.remotePlaylists(of: connectionID)
            .map { PlaylistID.remote(connection: connectionID, id: $0.id) }
            .sorted { $0 == active && $1 != active }
        for id in ids where needsContent(id) {
            await refreshContent(id)
        }
        states[connectionID]?.lastSync = Date()
        await watcher?.playlistsChanged(of: connectionID)
    }

    private static func info(of playlist: SubsonicPlaylist, username: String) -> RemotePlaylistInfo {
        let foreign = playlist.owner.map { $0.caseInsensitiveCompare(username) != .orderedSame } ?? false
        return RemotePlaylistInfo(id: playlist.id, name: playlist.name, owner: playlist.owner, isForeign: foreign,
                                  isReadOnly: playlist.isReadOnly, changed: playlist.changed, songCount: playlist.songCount)
    }

    /// The content isn't what the server has (as far as the listing says), and nothing of ours is on its way to it.
    private func needsContent(_ id: PlaylistID) -> Bool {
        guard pending[id] == nil, let info = store.remoteInfo(id) else { return false }
        if !info.isUpToDate { return true }
        // A server that doesn't date its playlists: the number of songs is all there is to tell.
        if info.changed == nil, let count = info.songCount, let cached = store.playlist(id), cached.trackCount != count {
            return true
        }
        return false
    }

    /// Reads one playlist from the server and makes the content match. Does nothing while a change of ours is waiting to
    /// be sent (it would be overwritten).
    func refreshContent(_ id: PlaylistID) async {
        guard case .remote(let connectionID, let remoteID) = id, let connection = service.connection(connectionID),
              pending[id] == nil else { return }
        do {
            let detail = try await connection.playlistContent(remoteID)
            noteSuccess(of: connectionID)
            guard pending[id] == nil else { return }
            await adopt(detail, as: id, connection: connection)
        } catch is CancellationError {
            return
        } catch let error as SubsonicError where error.kind == .notFound {
            Log.info("subsonic[\(connection.name)]: playlist \(remoteID) is not on the server (any more)")
        } catch {
            noteFailure(error, of: connectionID)
        }
    }

    /// Takes what the server has of a playlist over: the content (if it differs), and what is known about it.
    private func adopt(_ detail: (playlist: SubsonicPlaylist, songs: [SubsonicSong]), as id: PlaylistID,
                       connection: SubsonicConnection) async {
        guard let connectionID = id.connection, let current = await store.readPlaylist(id) else { return }
        let songs = detail.songs
        let updated = await Task.detached(priority: .userInitiated) {
            RemotePlaylistMerge.merged(current, songs: songs, connection: connectionID)
        }.value
        if !RemotePlaylistMerge.isSame(current, updated) {
            guard store.replaceRemoteContent(id, current: current, with: updated) else { return }   // changed here meanwhile
            if let watcher { Task { await watcher.playlistsChanged(of: connectionID) } }
        } else if store.playlist(id) !== current {
            return
        }
        let username = connection.config.username
        let fresh = Self.info(of: detail.playlist, username: username)
        store.updateRemoteInfo(id) {
            $0.name = fresh.name
            $0.owner = fresh.owner
            $0.isForeign = fresh.isForeign
            $0.isReadOnly = fresh.isReadOnly
            $0.changed = fresh.changed
            $0.songCount = songs.count
            $0.synced = fresh.changed ?? ""
        }

        // Grouped by albums: the server has the grouped order as well.
        let serverOrder = songs.map(\.id)
        if !updated.isFlat, updated.songIDs != serverOrder, rewrites[id] != serverOrder, store.remoteInfo(id)?.isOwnEditable == true,
           state(of: connectionID).isOnline {
            rewrites[id] = serverOrder
            Log.info("subsonic[\(connection.name)]: '\(store.displayName(of: id))' is shown grouped by albums, the server gets that order")
            markEdited(id, baseline: fresh.changed ?? "")
        }
        if id == store.activeID { ensureCovers(for: id) }
    }

    // MARK: - Covers

    /// Stores the thumbnails of the covers of a playlist's albums that have none yet, in the background (once per run).
    private func ensureCovers(for id: PlaylistID) {
        guard let connectionID = id.connection, let connection = service.connection(connectionID),
              let playlist = store.playlist(id), playlist.trackCount > 0, coversRequested.insert(id).inserted else { return }
        let albums = playlist.albums
        Task { [weak self] in
            let stored = await SubsonicImport.cacheCovers(of: albums, from: connection)
            if stored > 0 { self?.onCoversStored?() }
        }
    }

    func playlistWasOpened(_ id: PlaylistID) {
        guard let connection = id.connection else { return }
        ensureCovers(for: id)
        Task { await refresh(connection) }
    }

    // MARK: - Changes of the content

    func playlistWasEdited(_ id: PlaylistID, baseline: String?) {
        markEdited(id, baseline: baseline)
    }

    private func markEdited(_ id: PlaylistID, baseline: String?) {
        if pending[id] == nil {
            pending[id] = PendingEdit(baseline: baseline, dirty: true)
        } else {
            pending[id]?.dirty = true
        }
        store.updateRemoteInfo(id) { $0.synced = nil }
        if pushes[id] == nil {
            pushes[id] = Task { [weak self] in await self?.push(id) }
        }
        if let watcher, let connection = id.connection { Task { await watcher.playlistsChanged(of: connection) } }
    }

    /// Sends the order of the playlist as it is shown to the server, until what is shown is what was sent.
    private func push(_ id: PlaylistID) async {
        guard case .remote(let connectionID, let remoteID) = id, let connection = service.connection(connectionID) else {
            finishPush(id)
            return
        }
        var failure: Error?
        do {
            while pending[id]?.dirty == true {
                pending[id]?.dirty = false
                guard let local = store.playlist(id) else { break }
                let order = local.songIDs

                // Only change the version the user was looking at.
                let server = try await connection.playlistContent(remoteID)
                if let baseline = pending[id]?.baseline, !baseline.isEmpty, let changed = server.playlist.changed,
                   changed != baseline {
                    throw Conflict()
                }
                if order.isEmpty, !server.songs.isEmpty {
                    try await connection.updatePlaylist(remoteID, removingIndexes: Array(server.songs.indices))
                } else if order != server.songs.map(\.id) {
                    try await connection.replacePlaylist(remoteID, songIDs: order)
                }
                noteSuccess(of: connectionID)
                Log.info("subsonic[\(connection.name)]: '\(store.displayName(of: id))' saved on the server (\(order.count) track(s))")

                let saved = try await connection.playlistContent(remoteID)
                pending[id]?.baseline = saved.playlist.changed ?? ""
                if pending[id]?.dirty == true { continue }
                pending[id] = nil   // the content is the server's again
                await adopt(saved, as: id, connection: connection)   // (may find the grouped order to send, and make a new edit)
            }
        } catch is CancellationError {
            finishPush(id)
            return
        } catch {
            failure = error
        }
        finishPush(id)
        guard let failure else { return }

        let name = store.displayName(of: id)
        if failure is Conflict {
            Log.info("subsonic[\(connection.name)]: '\(name)' was changed on the server meanwhile, the change is dropped")
            onProblem?("Playlist Changed",
                       "“\(name)” was changed on the server in the meantime, so your change wasn't applied. The playlist shows what the server has.")
        } else {
            noteFailure(failure, of: connectionID, quietly: true)
            Log.error("subsonic[\(connection.name)]: can't save '\(name)': \(Self.text(of: failure))")
            onProblem?("Playlist Not Saved",
                       "Your change to “\(name)” couldn't be saved on the server: \(Self.text(of: failure)) The playlist will show what the server has.")
        }
        await refreshContent(id)
    }

    /// A change of the user's is on its way to a server.
    var hasPendingEdits: Bool { !pushes.isEmpty }

    /// Waits until what is on its way to the servers got there, for `timeout` at most (the app is quitting: a change that
    /// is not sent is dropped with the next look at the server).
    func flushEdits(timeout: Duration = .seconds(5)) async {
        guard hasPendingEdits else { return }
        let sleep = self.sleep
        let waiter = Task { [weak self] in
            while let self, self.hasPendingEdits, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let limit = Task {
            try? await sleep(timeout)
            waiter.cancel()
        }
        await waiter.value
        limit.cancel()
    }

    private func finishPush(_ id: PlaylistID) {
        pending[id] = nil
        pushes[id] = nil
    }

    private func forgetEdits(of id: PlaylistID) {
        pushes[id]?.cancel()
        pending[id] = nil
        pushes[id] = nil
        rewrites[id] = nil
        coversRequested.remove(id)
    }

    // MARK: - Adding songs, creating, renaming, deleting

    /// Adds songs at the end of a playlist (on the server first), then shows what the server has.
    func append(songIDs: [String], to id: PlaylistID) async throws {
        let connection = try editableConnection(for: id)
        guard case .remote(_, let remoteID) = id else { return }
        await pushes[id]?.value   // what was changed here before goes first
        do {
            try await connection.updatePlaylist(remoteID, adding: songIDs)
        } catch {
            noteFailure(error, of: id.connection)
            throw error
        }
        noteSuccess(of: id.connection)
        Log.info("subsonic[\(connection.name)]: \(songIDs.count) song(s) added to '\(store.displayName(of: id))'")
        await refreshContent(id)
    }

    /// Makes a new, empty playlist on the server (private, as the server makes it) and opens it.
    func createPlaylist(named rawName: String, on connectionID: UUID) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlaylistError.emptyName }
        guard let connection = service.connection(connectionID) else {
            throw SubsonicError(.rejected, "the connection is switched off")
        }
        structureEpoch[connectionID, default: 0] += 1
        var created: SubsonicPlaylist?
        do {
            let known = Set(store.remotePlaylists(of: connectionID).map(\.id))
            created = try await connection.createPlaylist(name: name)
            if created == nil {   // a server from before 1.14 doesn't say which one it made
                created = try await connection.playlists().last { !known.contains($0.id) && $0.name == name }
            }
        } catch {
            noteFailure(error, of: connectionID)
            throw error
        }
        structureEpoch[connectionID, default: 0] += 1
        noteSuccess(of: connectionID)
        guard let created else { throw SubsonicError(.rejected, "the server didn't say which playlist it made") }
        let username = connection.config.username
        var info = Self.info(of: created, username: username)
        info.synced = created.changed ?? ""
        info.songCount = 0
        Log.info("subsonic[\(connection.name)]: playlist '\(name)' created")
        store.addRemote(info, of: connectionID)
    }

    func renamePlaylist(_ id: PlaylistID, to rawName: String) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlaylistError.emptyName }
        let connection = try editableConnection(for: id)
        guard case .remote(let connectionID, let remoteID) = id else { return }
        await pushes[id]?.value
        structureEpoch[connectionID, default: 0] += 1
        do {
            try await connection.updatePlaylist(remoteID, name: name)
        } catch {
            noteFailure(error, of: connectionID)
            throw error
        }
        structureEpoch[connectionID, default: 0] += 1
        noteSuccess(of: connectionID)
        Log.info("subsonic[\(connection.name)]: playlist '\(store.displayName(of: id))' renamed to '\(name)'")
        store.updateRemoteInfo(id) { $0.name = name }
        await refreshContent(id)   // the server dates it anew
    }

    /// Deletes the playlist on the server, then here: its cached content, and the downloaded files of the songs that no
    /// other playlist of the connection has.
    func deletePlaylist(_ id: PlaylistID) async throws {
        let connection = try editableConnection(for: id)
        guard case .remote(let connectionID, let remoteID) = id else { return }
        await pushes[id]?.value
        let songs = (await store.readPlaylist(id))?.entries.compactMap(\.subsonic) ?? []
        structureEpoch[connectionID, default: 0] += 1
        do {
            try await connection.deletePlaylist(remoteID)
        } catch {
            noteFailure(error, of: connectionID)
            throw error
        }
        structureEpoch[connectionID, default: 0] += 1
        noteSuccess(of: connectionID)
        Log.info("subsonic[\(connection.name)]: playlist '\(store.displayName(of: id))' deleted")
        forgetEdits(of: id)
        store.removeRemote(id)
        await watcher?.playlistsChanged(of: connectionID)   // what it kept for the playlist may be free now
        await removeFiles(of: songs, connection: connectionID)
    }

    // MARK: - Internals

    /// The connection of a playlist that can be changed, or the reason why not.
    private func editableConnection(for id: PlaylistID) throws -> SubsonicConnection {
        guard let connectionID = id.connection, store.remoteInfo(id) != nil else {
            throw PlaylistError.notFound(store.displayName(of: id))
        }
        guard let connection = service.connection(connectionID) else {
            throw SubsonicError(.rejected, "the connection is switched off")
        }
        if let reason = readOnlyReason(id) {
            throw SubsonicError(.rejected, "this playlist is read-only: \(reason)")
        }
        return connection
    }

    /// Deletes the downloaded files of these songs, except those that a playlist of the connection still has.
    private func removeFiles(of songs: [SubsonicRef], connection: UUID) async {
        var kept = Set<String>()
        for info in store.remotePlaylists(of: connection) {
            let id = PlaylistID.remote(connection: connection, id: info.id)
            if let content = await store.readPlaylist(id) {
                kept.formUnion(content.entries.compactMap { $0.subsonic?.songID })
            }
        }
        var seen = Set<String>()
        let unused = songs.filter { !kept.contains($0.songID) && seen.insert($0.songID).inserted }
        guard !unused.isEmpty else { return }
        let remover = files ?? SubsonicDownloads.shared
        files = remover
        let removed = remover.removeFiles(ofSongs: unused)
        if removed > 0 { Log.info("subsonic: \(removed) downloaded file(s) of removed playlist(s) deleted") }
    }

    private func noteSuccess(of connection: UUID?) {
        guard let connection else { return }
        var state = states[connection] ?? SubsonicPlaylistsState()
        if !state.isOnline, state.error != nil {
            Log.info("subsonic: the playlists of \"\(service.displayName(of: connection))\" can be synced again")
        }
        state.isOnline = true
        state.error = nil
        states[connection] = state
    }

    /// `quietly`: only a failure to reach the server counts (the server saying no to a change isn't a reason to stop).
    private func noteFailure(_ error: Error, of connection: UUID?, quietly: Bool = false) {
        guard let connection else { return }
        if quietly, (error as? SubsonicError)?.kind != .connection { return }
        let message = Self.text(of: error)
        var state = states[connection] ?? SubsonicPlaylistsState()
        if state.error != message {
            Log.error("subsonic: the playlists of \"\(service.displayName(of: connection))\" can't be synced: \(message)")
        }
        state.isOnline = false
        state.error = message
        states[connection] = state
    }

    private static func text(of error: Error) -> String {
        if let error = error as? SubsonicError { return SubsonicService.sentence(error.message) }
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return SubsonicService.sentence(error.localizedDescription)
    }
}
