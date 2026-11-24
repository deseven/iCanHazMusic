// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum PlaylistError: LocalizedError {
    case emptyName
    case forbiddenCharacters
    case leadingDot
    case nameTooLong
    case alreadyExists(String)
    case lastPlaylist
    case notFound(String)
    case io(Error)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "The playlist name can't be empty."
        case .forbiddenCharacters:
            "The playlist name can't contain any of these characters: / \\ : * ? \" < > |"
        case .leadingDot:
            "The playlist name can't start with a dot."
        case .nameTooLong:
            "The playlist name is too long."
        case .alreadyExists(let name):
            "A playlist named “\(name)” already exists."
        case .lastPlaylist:
            "The last remaining playlist can't be deleted."
        case .notFound(let name):
            "The playlist “\(name)” doesn't exist."
        case .io(let error):
            "File operation failed: \(error.localizedDescription)"
        }
    }
}

/// The playlists of one enabled Subsonic connection, as the selector shows them.
struct RemoteSection: Equatable {
    let connection: UUID
    /// The connection's name.
    var name: String
    /// Sorted by name (`RemotePlaylistInfo.isOrderedBefore`).
    var playlists: [RemotePlaylistInfo]
}

/// All playlists and the currently active one: the local ones (`playlists/*.json`, known by their names) and those of
/// the enabled Subsonic connections (`remoteSections`, known by the server's IDs, see `PlaylistID`).
///
/// Every playlist is kept in memory (search needs them all), but only the active one is shown: `activePlaylist`
/// is what the UI gets, the others are not pushed anywhere. At launch the active playlist is read first, then the
/// others one after the other in the background (`isPreloading`); a playlist that is selected before its turn is
/// read at once. A playlist leaves memory only when it is deleted (or its connection is switched off). `playingID` is
/// the playlist playback runs from, which is not necessarily the active one.
/// The file format is `PlaylistFile`; loading is asynchronous (`isLoading`), content changes are written back in the
/// background.
///
/// Remote playlists: the server is what counts, this store holds the copy of it (`.cache/subsonic/{connection}/playlists`:
/// the index with what the server said about them, `RemotePlaylistIndex`, and the content of each). It is changed by
/// `SubsonicPlaylists`, which talks to the servers (`setRemotePlaylists`, `replaceRemoteContent`, ...), and edited
/// here like a local one, which `remoteEditor` is told of so the server gets it too. Only what `remoteEditor` allows
/// (`canEdit`) can be edited.
@MainActor
@Observable
final class PlaylistStore {
    static let shared = PlaylistStore(paths: .current, configStore: .shared)

    /// Names of the local playlists, sorted alphabetically.
    private(set) var names: [String] = []
    /// The enabled Subsonic connections (in the order they are shown) with their playlists.
    private(set) var remoteSections: [RemoteSection] = []
    private(set) var activeID: PlaylistID = .local("")

    /// Content of the active playlist. Empty while `isLoading`.
    private(set) var activePlaylist: Playlist = .empty
    /// The active playlist is being read from disk. It can't be modified until that's done.
    private(set) var isLoading = false
    /// The other playlists are being read from disk (after the active one, in the background).
    private(set) var isPreloading = false
    /// Counts how often a playlist has been opened: became the active one with its content in place (loaded from
    /// disk, or already in memory). The view reacts to this by showing `lastPlayedRow`.
    private(set) var openCount = 0


    /// Files whose tags are read at the same time on an import; `ConfigLimits.tagParsingConcurrencyAuto` (0) =
    /// automatic. Persisted in the config.
    var tagParsingConcurrency = ConfigLimits.tagParsingConcurrencyAuto {
        didSet {
            guard tagParsingConcurrency != oldValue else { return }
            configStore.update { $0.engine.tagParsingConcurrency = tagParsingConcurrency }
        }
    }

    /// `tagParsingConcurrency` with the automatic setting resolved.
    var effectiveTagParsingConcurrency: Int {
        tagParsingConcurrency == ConfigLimits.tagParsingConcurrencyAuto
            ? TagReader.defaultConcurrency : tagParsingConcurrency
    }

    /// The queue is shown in place of the active playlist (which stays the active one: it is where files are added
    /// and what the cursor is in). Cleared by opening any playlist.
    private(set) var isQueueShown = false

    /// The playlist playback runs from, if any (set through `playbackStarted`/`playbackEnded`).
    private(set) var playingID: PlaylistID?
    /// Every playlist that has been read (key: `key(id)`), the active one included once it is loaded.
    @ObservationIgnored private var loaded: [String: Playlist] = [:]
    /// The playback running from this store's playlists (set by `PlaybackState` itself): told when the playing
    /// playlist grows or is deleted.
    @ObservationIgnored weak var playback: PlaybackState?
    /// Keeps the remote playlists in step with their servers; asked whether one can be edited and told when one was.
    /// Without it (tests of local playlists) remote playlists can't be edited.
    @ObservationIgnored weak var remoteEditor: RemotePlaylistEditing?

    @ObservationIgnored private let fm = FileManager.default
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    /// Writes are chained so they hit the disk in the order they were requested.
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWrites = 0
    /// Number of the newest write queued for each file (key: `key(id)`, or `indexKey`): older ones still waiting in the
    /// chain are covered by it and skipped.
    @ObservationIgnored private var saveSerial: [String: Int] = [:]
    /// The last played track of every playlist (key: `key(id)`), kept apart from the playlist files so that starting a
    /// track doesn't rewrite one. A `last_played` in a file (older versions) only seeds it, see `adopt`.
    @ObservationIgnored private let lastPlayedStore: LastPlayedStore
    /// The row of the active playlist that `reveal` wants shown when the view reacts to the opening.
    @ObservationIgnored private var pendingReveal: Int?

    private static let maxNameBytes = 200

    init(paths: AppPaths, configStore: ConfigStore) {
        self.paths = paths
        self.configStore = configStore
        lastPlayedStore = LastPlayedStore(url: paths.lastPlayedURL)

        tagParsingConcurrency = configStore.config.engine.tagParsingConcurrency
        do {
            try fm.createDirectory(at: paths.playlistsDir, withIntermediateDirectories: true)
        } catch {
            Log.error("can't create \(paths.playlistsDir.path): \(error.localizedDescription)")
        }

        reload()

        if names.isEmpty {
            Log.info("no playlists found, creating '\(AppConfig.defaultPlaylistName)'")
            do {
                try writeEmptyPlaylist(named: AppConfig.defaultPlaylistName)
                reload()
            } catch {
                Log.error("can't create default playlist: \(error.localizedDescription)")
            }
        }

        // The playlists of the enabled connections as they were seen last; the servers are asked later (`SubsonicPlaylists`).
        remoteSections = configStore.config.subsonic.filter(\.enabled).map { connection in
            RemoteSection(connection: connection.id, name: connection.displayName, playlists: readIndex(of: connection.id))
        }

        let knownKeys = Set(names.map { Self.key($0) })
        let connections = Set(configStore.config.subsonic.map(\.id))
        lastPlayedStore.prune { key in
            if let connection = PlaylistID(text: key).connection { return connections.contains(connection) }
            return knownKeys.contains(key)
        }

        // Fall back to the first playlist if the configured one is gone.
        let saved = PlaylistID(text: configStore.config.activePlaylist)
        if let match = existing(saved) {
            activeID = match
        } else if let first = names.first {
            Log.info("active playlist '\(configStore.config.activePlaylist)' not found, switching to '\(first)'")
            activeID = .local(first)
        }
        syncActiveToConfig()
        if exists(activeID) { startLoad() }
    }

    // MARK: - Queries

    /// Every playlist: the local ones, then those of each connection, in the order they are shown.
    var ids: [PlaylistID] {
        names.map { PlaylistID.local($0) } + remoteSections.flatMap { section in
            section.playlists.map { PlaylistID.remote(connection: section.connection, id: $0.id) }
        }
    }

    /// How many playlists there are, local and remote.
    var count: Int {
        names.count + remoteSections.reduce(0) { $0 + $1.playlists.count }
    }

    func exists(_ id: PlaylistID) -> Bool {
        existing(id) != nil
    }

    /// What the server said about a remote playlist (nil for a local one, or one that isn't there).
    func remoteInfo(_ id: PlaylistID) -> RemotePlaylistInfo? {
        guard case .remote(let connection, let remoteID) = id else { return nil }
        return remoteSections.first { $0.connection == connection }?.playlists.first { $0.id == remoteID }
    }

    /// The playlists of an enabled connection (none for one that isn't).
    func remotePlaylists(of connection: UUID) -> [RemotePlaylistInfo] {
        remoteSections.first { $0.connection == connection }?.playlists ?? []
    }

    /// What a playlist is called: its name. For a remote one that isn't there (any more) a placeholder.
    func displayName(of id: PlaylistID) -> String {
        switch id {
        case .local(let name): existing(id)?.localName ?? name
        case .remote: remoteInfo(id)?.name ?? "a removed playlist"
        }
    }

    /// The name of the connection of a remote playlist (nil for a local one or a connection that is switched off).
    func connectionName(of id: PlaylistID) -> String? {
        guard let connection = id.connection else { return nil }
        return remoteSections.first { $0.connection == connection }?.name
    }

    /// What a playlist is called where playlists of several sources are listed together (search results, the queue):
    /// "Name (Connection)" for a remote one.
    func qualifiedName(of id: PlaylistID) -> String {
        guard let connection = connectionName(of: id) else { return displayName(of: id) }
        return "\(displayName(of: id)) (\(connection))"
    }

    /// Whether the playlist's content can be changed now: always for a local one; for a remote one when `remoteEditor`
    /// says so (it is the user's and the server can be reached).
    func canEdit(_ id: PlaylistID) -> Bool {
        guard let match = existing(id) else { return false }
        guard match.isRemote else { return true }
        return remoteEditor?.canEdit(match) ?? false
    }

    /// Whether a write is still queued or running (the app must not quit yet).
    var hasPendingWrites: Bool { pendingWrites > 0 }

    /// Content of the playlist playback runs from, whether it's the active one or not.
    var playingPlaylist: Playlist? {
        guard let playing = playingID else { return nil }
        return loaded[Self.key(playing)]
    }

    /// The content of a playlist that is in memory (the active one while it is still being read isn't).
    func playlist(_ id: PlaylistID) -> Playlist? {
        loaded[Self.key(id)]
    }

    /// The content of a playlist, once it is in memory: waits for the active one to be read, and reads any other one
    /// that the background preload hasn't got to yet. `nil` if there is no such playlist (any more).
    func readPlaylist(_ id: PlaylistID) async -> Playlist? {
        guard let match = existing(id) else { return nil }
        let key = Self.key(match)
        if loaded[key] == nil, isLoading, key == Self.key(activeID) { await loadTask?.value }
        if let ready = loaded[key] { return ready }

        await flushWrites()
        if let ready = loaded[key] { return ready }   // read by somebody else meanwhile
        let url = fileURL(match)
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) { PlaylistFile.load(from: url) }.value
        guard exists(match) else { return nil }   // deleted or renamed meanwhile
        return adopt(result, id: match, started: started)
    }

    /// The playlists that are in memory, in the order of `ids`.
    var loadedPlaylists: [(id: PlaylistID, playlist: Playlist)] {
        ids.compactMap { id in loaded[Self.key(id)].map { (id, $0) } }
    }

    /// The ID of the track that was started last in this playlist (it is in memory and has that track), if any.
    func lastPlayed(in id: PlaylistID) -> TrackID? {
        let key = Self.key(id)
        guard loaded[key] != nil else { return nil }
        return lastPlayedStore[key]
    }

    /// Returns once the active playlist is in memory (at once if it is). A load that is replaced by another (the
    /// active playlist changed meanwhile) is waited for as well.
    func waitUntilLoaded() async {
        while isLoading, let task = loadTask {
            await task.value
        }
    }

    /// The row of the active playlist's last played track (see `setLastPlayed`), if it is loaded and has it.
    var lastPlayedRow: Int? {
        guard !isLoading, let id = lastPlayedStore[Self.key(activeID)] else { return nil }
        return activePlaylist.row(of: id)
    }

    /// Playback runs from the playlist that is currently shown (and it is loaded).
    var playingIsActive: Bool {
        guard let playing = playingID, !isLoading else { return false }
        return Self.key(playing) == Self.key(activeID)
    }

    /// Playback has started from the active playlist.
    func playbackStarted() {
        guard !isLoading, exists(activeID) else { return }
        playingID = activeID
    }

    /// Playback has started from another playlist than the active one (a queued track): it is in memory.
    func playbackStarted(in id: PlaylistID) {
        guard let match = existing(id), loaded[Self.key(match)] != nil else { return }
        playingID = match
    }

    func playbackEnded() {
        playingID = nil
    }

    func showQueue() {
        isQueueShown = true
    }

    func hideQueue() {
        isQueueShown = false
    }

    // MARK: - Mutations

    /// Adds albums at the end of the active playlist and stores it. Ignored for any other playlist, for a remote one
    /// (their tracks are added on the server, see `SubsonicPlaylists.append`) and while the active one is still loading.
    func append(_ albums: [Album], to id: PlaylistID) async {
        guard !albums.isEmpty, !isLoading, let match = existing(id), !match.isRemote,
              Self.key(match) == Self.key(activeID) else { return }

        let current = activePlaylist
        let updated = await Task.detached(priority: .userInitiated) { current.appending(albums) }.value
        // Something else replaced the content in the meantime (can't happen behind the modal import sheet).
        guard activePlaylist === current else { return }

        commit(updated, as: match)
        save(updated, as: match)
        if let playing = playingID, Self.key(playing) == Self.key(match) {
            playback?.playlistDidChange()
        }
    }

    /// Removes these tracks from the active playlist (see `Playlist.trackIDs`). Playback stops if its track is
    /// among them.
    func remove(ids removed: Set<TrackID>, from id: PlaylistID) async {
        guard !removed.isEmpty, canEdit(id) else { return }
        guard await replaceActive(id, { $0.removing(ids: removed) }), let match = existing(id) else { return }
        playback?.queue.remove(ids: removed, fromPlaylist: match)
        edited(match)
    }

    /// Moves a track to another place inside its album in the active playlist (drag and drop). Synchronous (a
    /// reordering is cheap), so the caller knows at once whether it was applied. Returns `false` if it wasn't (see
    /// `Playlist.movingTrack`; or the playlist isn't the active one / is still loading / can't be edited).
    @discardableResult
    func moveTrack(id: TrackID, toIndexInAlbum index: Int, in playlistID: PlaylistID) -> Bool {
        guard !isLoading, canEdit(playlistID), let match = existing(playlistID), Self.key(match) == Self.key(activeID),
              let updated = activePlaylist.movingTrack(id: id, toIndexInAlbum: index) else { return false }
        Log.info("moved track \(id) to place \(index) of its album in '\(displayName(of: match))'")
        install(updated, replacing: activePlaylist, as: match)
        edited(match)
        return true
    }

    /// Moves an album (a track in a flat playlist) to another place in the active playlist (drag and drop); see
    /// `moveTrack`.
    @discardableResult
    func moveAlbum(_ album: Int, to index: Int, in playlistID: PlaylistID) -> Bool {
        guard !isLoading, canEdit(playlistID), let match = existing(playlistID), Self.key(match) == Self.key(activeID),
              let updated = activePlaylist.movingAlbum(album, to: index) else { return false }
        Log.info("moved album \(album) to place \(index) in '\(displayName(of: match))'")
        install(updated, replacing: activePlaylist, as: match)
        edited(match)
        return true
    }

    /// Takes over freshly read tags into the active playlist and regroups it (see `Playlist.updatingTags`).
    func applyTags(_ results: [TagReadResult], to id: PlaylistID) async {
        guard !results.isEmpty else { return }
        await replaceActive(id) { $0.updatingTags(from: results) }
    }

    /// Turns the album grouping of the active playlist off or on ("Don't group by albums") and stores it. Grouping a
    /// remote playlist that can be edited reorders it on the server too (the albums' tracks come together); one that
    /// can't be edited is only shown grouped.
    func setFlat(_ flat: Bool) async {
        guard !isLoading, activePlaylist.isFlat != flat else { return }
        let id = activeID
        if !flat, let info = remoteInfo(id), info.isOwnEditable, !canEdit(id) { return }   // would reorder it later
        let reorders = !flat && id.isRemote && canEdit(id)
        guard await replaceActive(id, { $0.settingFlat(flat) }) else { return }
        if reorders { edited(id) }
    }

    /// Records what playback found out about the file it plays: the real duration and format. Applied to the
    /// playlist playback runs from (shown or not), if it still has that track.
    func updateTrack(id: TrackID, duration: TimeInterval, codec: String) {
        guard let playing = playingID, let current = playingPlaylist,
              let updated = current.replacingTrack(id: id, duration: duration, codec: codec) else { return }
        commit(updated, as: playing)
        save(updated, as: playing)
    }

    /// Playback has started this track of the playlist it runs from: it is that playlist's last played one, which
    /// is remembered (and shown again when the playlist is opened). Only `LastPlayedStore` is written, not the playlist.
    func setLastPlayed(_ id: TrackID) {
        guard let playing = playingID, let playlist = playingPlaylist, playlist.position(of: id) != nil else { return }
        lastPlayedStore[Self.key(playing)] = id
    }

    /// Waits until everything queued by `save` is on disk, and writes the last played tracks if they changed.
    func flushWrites() async {
        await writeTask?.value
        lastPlayedStore.flush()
    }

    /// Opens a playlist that is in memory and has the view show one of its tracks (or the header of its album with
    /// `wholeAlbum`) instead of the last played one: see `takeReveal`. Does nothing if the playlist or the track
    /// isn't there.
    func reveal(trackID: TrackID, inPlaylist id: PlaylistID, wholeAlbum: Bool = false) {
        guard let match = existing(id), let playlist = loaded[Self.key(match)],
              let pos = playlist.position(of: trackID) else { return }
        let row = wholeAlbum && !playlist.isFlat ? playlist.headerRow[pos.album] : playlist.row(of: trackID)
        let changed = Self.key(match) != Self.key(activeID)
        setActive(match)
        pendingReveal = row
        if !changed { openCount += 1 }   // the view has to be pointed at the row though nothing was opened
    }

    /// The row `reveal` asked for, once (read when the view reacts to `openCount`).
    func takeReveal() -> Int? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    func setActive(_ id: PlaylistID) {
        guard let match = existing(id) else { return }
        let changed = Self.key(match) != Self.key(activeID)
        if isQueueShown {
            // Back from the queue: the view is rebuilt, so it has to be pointed at the track again.
            isQueueShown = false
            if !changed { openCount += 1 }
        }
        activeID = match
        syncActiveToConfig()
        guard changed else { return }
        pendingReveal = nil

        if let ready = loaded[Self.key(match)] {
            loadTask?.cancel()
            activePlaylist = ready
            isLoading = false
            openCount += 1
            startPreload()   // a load that was cancelled just now would have started it
        } else {
            startLoad()
        }
        if match.isRemote { remoteEditor?.playlistWasOpened(match) }
    }

    /// Creates a new empty local playlist and makes it active. Returns the final name.
    @discardableResult
    func create(named rawName: String) throws -> String {
        let name = try Self.validate(rawName)
        guard !exists(.local(name)) else { throw PlaylistError.alreadyExists(name) }

        do {
            try writeEmptyPlaylist(named: name)
        } catch {
            throw PlaylistError.io(error)
        }
        reload()
        setActive(.local(name))
        return name
    }

    /// Renames a local playlist.
    func rename(_ oldName: String, to rawName: String) async throws {
        // A queued write would otherwise recreate the old file.
        await flushWrites()
        let newName = try Self.validate(rawName)
        guard let current = existingName(matching: oldName) else { throw PlaylistError.notFound(oldName) }
        guard newName != current else { return }

        let sameFile = Self.key(newName) == Self.key(current)
        if !sameFile, exists(.local(newName)) { throw PlaylistError.alreadyExists(newName) }

        do {
            if sameFile {
                // Only the letter case differs; on a case-insensitive volume that's the same file,
                // so go through a temporary name.
                let temp = paths.playlistsDir.appendingPathComponent(".rename-\(UUID().uuidString)")
                try fm.moveItem(at: fileURL(.local(current)), to: temp)
                try fm.moveItem(at: temp, to: fileURL(.local(newName)))
            } else {
                try fm.moveItem(at: fileURL(.local(current)), to: fileURL(.local(newName)))
            }
        } catch {
            throw PlaylistError.io(error)
        }

        let oldID = PlaylistID.local(current)
        let oldKey = Self.key(oldID)
        let wasActive = Self.key(activeID) == oldKey
        reload()
        let finalID = PlaylistID.local(existingName(matching: newName) ?? newName)
        let newKey = Self.key(finalID)
        if let last = lastPlayedStore[oldKey] {
            lastPlayedStore[oldKey] = nil
            lastPlayedStore[newKey] = last
        }
        if let playing = playingID, Self.key(playing) == oldKey { playingID = finalID }
        playback?.queue.renamePlaylist(from: oldID, to: finalID)
        if let content = loaded.removeValue(forKey: oldKey) { loaded[newKey] = content }
        startPreload()   // a read of the old file may have come back empty-handed
        if wasActive {
            // Same playlist under a new name: keep the loaded content.
            activeID = finalID
            syncActiveToConfig()
            if isLoading {
                startLoad()   // the file being read has just moved; the load counts as the opening
            } else {
                openCount += 1   // the view is rebuilt for the new name, so it has to be pointed at the track again
            }
        }
    }

    /// Deletes a local playlist (not the last one).
    func delete(_ name: String) async throws {
        await flushWrites()
        guard let current = existingName(matching: name) else { throw PlaylistError.notFound(name) }
        guard names.count > 1 else { throw PlaylistError.lastPlaylist }

        do {
            try fm.removeItem(at: fileURL(.local(current)))
        } catch {
            throw PlaylistError.io(error)
        }

        let id = PlaylistID.local(current)
        forget(id)
        lastPlayedStore[Self.key(id)] = nil
        reload()
        if Self.key(activeID) == Self.key(id), let first = names.first { setActive(.local(first)) }
    }

    // MARK: - Remote playlists

    /// The Subsonic connections that are switched on, in the order they are shown. The playlists of a connection that is
    /// new here are read from its cache; those of a connection that is gone leave memory (playback from them stops, their
    /// queued tracks go; the cache stays, see `SubsonicDownloads` for what happens to it).
    func setConnections(_ connections: [(id: UUID, name: String)]) {
        let old = remoteSections
        let kept = Set(connections.map(\.id))
        for section in old where !kept.contains(section.connection) {
            Log.info("playlists of \"\(section.name)\" are hidden: the connection is off")
            for info in section.playlists { forget(.remote(connection: section.connection, id: info.id)) }
        }
        remoteSections = connections.map { connection in
            if var known = old.first(where: { $0.connection == connection.id }) {
                known.name = connection.name
                return known
            }
            return RemoteSection(connection: connection.id, name: connection.name, playlists: readIndex(of: connection.id))
        }
        fallBackIfActiveIsGone()
        startPreload()
    }

    /// What the server lists now: new playlists are added (empty until their content comes, flat), those that are gone
    /// are deleted (see `removeRemote`), the others take over what the server says of them (the cached content stays
    /// until `replaceRemoteContent`; `synced` and `autoDownload` are the app's own and stay too). Ignored for a
    /// connection that isn't enabled.
    func setRemotePlaylists(_ listed: [RemotePlaylistInfo], of connection: UUID) {
        guard let index = remoteSections.firstIndex(where: { $0.connection == connection }) else { return }
        let old = remoteSections[index].playlists
        let listedIDs = Set(listed.map(\.id))
        for gone in old where !listedIDs.contains(gone.id) {
            removeRemote(.remote(connection: connection, id: gone.id))
        }
        let merged = listed.map { info in
            var info = info
            let known = old.first { $0.id == info.id }
            info.synced = known?.synced
            info.autoDownload = known?.autoDownload ?? false   // the app's own, not the server's
            return info
        }.sorted(by: RemotePlaylistInfo.isOrderedBefore)
        guard let current = remoteSections.firstIndex(where: { $0.connection == connection }),
              remoteSections[current].playlists != merged else { return }
        remoteSections[current].playlists = merged
        saveIndex(of: connection)
        startPreload()
    }

    /// Adds a playlist that was just made on the server (empty, flat) and makes it active.
    func addRemote(_ info: RemotePlaylistInfo, of connection: UUID) {
        guard let index = remoteSections.firstIndex(where: { $0.connection == connection }) else { return }
        let id = PlaylistID.remote(connection: connection, id: info.id)
        if !remoteSections[index].playlists.contains(where: { $0.id == info.id }) {
            remoteSections[index].playlists = (remoteSections[index].playlists + [info]).sorted(by: RemotePlaylistInfo.isOrderedBefore)
            saveIndex(of: connection)
        }
        let content = Playlist(albums: [], isFlat: true)
        loaded[Self.key(id)] = content
        save(content, as: id)
        setActive(id)
    }

    /// Changes what is known about a remote playlist (its name after a rename, the version of the content).
    func updateRemoteInfo(_ id: PlaylistID, _ change: (inout RemotePlaylistInfo) -> Void) {
        guard case .remote(let connection, let remoteID) = id,
              let section = remoteSections.firstIndex(where: { $0.connection == connection }),
              let index = remoteSections[section].playlists.firstIndex(where: { $0.id == remoteID }) else { return }
        var info = remoteSections[section].playlists[index]
        change(&info)
        guard info != remoteSections[section].playlists[index] else { return }
        var playlists = remoteSections[section].playlists
        playlists[index] = info
        remoteSections[section].playlists = playlists.sorted(by: RemotePlaylistInfo.isOrderedBefore)
        saveIndex(of: connection)
    }

    /// Puts what the server has (`updated`, made out of `current`) in place of a remote playlist's content, if the
    /// content is still `current` (else nothing is done and `false` returned: it changed meanwhile). Tracks that are gone
    /// leave the queue; playback finds its track again by its ID.
    @discardableResult
    func replaceRemoteContent(_ id: PlaylistID, current: Playlist, with updated: Playlist) -> Bool {
        guard id.isRemote, let match = existing(id), let present = loaded[Self.key(match)], present === current else { return false }
        let removed = Set(current.albums.flatMap { $0.tracks.map(\.id) })
            .subtracting(updated.albums.flatMap { $0.tracks.map(\.id) })
        install(updated, replacing: current, as: match)
        if !removed.isEmpty { playback?.queue.remove(ids: removed, fromPlaylist: match) }
        return true
    }

    /// A remote playlist is gone (deleted here or on the server): it leaves memory like a deleted local one (playback
    /// from it stops, its queued tracks go) and its cached content is deleted. Another playlist is opened if it was the
    /// active one.
    func removeRemote(_ id: PlaylistID) {
        guard case .remote(let connection, let remoteID) = id,
              let section = remoteSections.firstIndex(where: { $0.connection == connection }),
              remoteSections[section].playlists.contains(where: { $0.id == remoteID }) else { return }
        Log.info("remote playlist '\(displayName(of: id))' of \"\(remoteSections[section].name)\" is gone")
        forget(id)
        lastPlayedStore[Self.key(id)] = nil
        let file = fileURL(id)
        queueWrite(key: Self.key(id), label: "delete '\(id)'") { try? FileManager.default.removeItem(at: file) }
        remoteSections[section].playlists.removeAll { $0.id == remoteID }
        saveIndex(of: connection)
        fallBackIfActiveIsGone()
    }

    // MARK: - Internals

    /// Replaces the content of the active playlist with `transform` of it (run off the main thread), stores it
    /// and tells playback, which has to find its track again by its ID. A last played track that is gone is forgotten.
    /// Ignored for any other playlist and while the active one is still loading.
    /// Returns whether the content was replaced.
    @discardableResult
    private func replaceActive(_ id: PlaylistID, _ transform: @escaping (Playlist) -> Playlist) async -> Bool {
        guard !isLoading, let match = existing(id), Self.key(match) == Self.key(activeID) else { return false }

        let current = activePlaylist
        let updated = await Task.detached(priority: .userInitiated) { transform(current) }.value
        guard activePlaylist === current else { return false }   // something else replaced the content in the meantime

        install(updated, replacing: current, as: match)
        return true
    }

    /// Puts `updated` in place of the content `current` of a playlist that is in memory, stores it and tells playback.
    private func install(_ updated: Playlist, replacing current: Playlist, as match: PlaylistID) {
        commit(updated, as: match)
        let key = Self.key(match)
        if let last = lastPlayedStore[key], updated.position(of: last) == nil { lastPlayedStore[key] = nil }
        save(updated, as: match)
        if let playing = playingID, Self.key(playing) == key {
            playback?.playlistWasReplaced(from: current, to: updated)
        } else {
            playback?.playlistDidChange()   // a queued track may be in it, at another place now
        }
    }

    /// A remote playlist was changed here: its content is no longer what the server has until the server confirms it,
    /// and the server is to get it.
    private func edited(_ id: PlaylistID) {
        guard id.isRemote else { return }
        let baseline = remoteInfo(id)?.synced
        updateRemoteInfo(id) { $0.synced = nil }
        remoteEditor?.playlistWasEdited(id, baseline: baseline)
    }

    /// Takes a playlist out of memory (it was deleted, or its connection switched off): playback from it stops, its
    /// queued tracks go, its writes that are still queued are skipped.
    private func forget(_ id: PlaylistID) {
        let key = Self.key(id)
        if let playing = playingID, Self.key(playing) == key {
            playback?.halt()   // also releases the playlist held for the playback; the queue is kept (minus this playlist's tracks)
        }
        playback?.queue.removeAll(inPlaylist: id)
        loaded[key] = nil
        saveSerial[key, default: 0] += 1
    }

    /// Opens the first local playlist if the active one is gone.
    private func fallBackIfActiveIsGone() {
        guard !exists(activeID), let first = names.first else { return }
        setActive(.local(first))
    }

    // MARK: Validation

    /// Trims the name and checks that it can safely be used as a file name.
    static func validate(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlaylistError.emptyName }

        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        guard name.rangeOfCharacter(from: forbidden) == nil else { throw PlaylistError.forbiddenCharacters }
        guard !name.hasPrefix(".") else { throw PlaylistError.leadingDot }
        guard name.utf8.count <= maxNameBytes else { throw PlaylistError.nameTooLong }
        return name
    }

    // MARK: Identities and files

    /// APFS/HFS+ ignore letter case and Unicode normalization form in file names, so do we for local playlists. A
    /// remote playlist is its text (it has a `:`, which no local name has).
    private static func key(_ id: PlaylistID) -> String {
        switch id {
        case .local(let name): key(name)
        case .remote: id.text
        }
    }

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The playlist as the store has it (a local name in its own spelling), nil if there is no such playlist.
    private func existing(_ id: PlaylistID) -> PlaylistID? {
        switch id {
        case .local(let name): existingName(matching: name).map { .local($0) }
        case .remote: remoteInfo(id) != nil ? id : nil
        }
    }

    private func existingName(matching name: String) -> String? {
        let k = Self.key(name)
        return names.first { Self.key($0) == k }
    }

    private func fileURL(_ id: PlaylistID) -> URL {
        switch id {
        case .local(let name):
            paths.playlistsDir.appendingPathComponent(name + ".json")
        case .remote(let connection, let remoteID):
            paths.subsonicPlaylistsDir(of: connection).appendingPathComponent(RemotePlaylistIndex.fileName(of: remoteID))
        }
    }

    private func indexURL(of connection: UUID) -> URL {
        paths.subsonicPlaylistsDir(of: connection).appendingPathComponent(RemotePlaylistIndex.fileName)
    }

    private static func indexKey(_ connection: UUID) -> String {
        "\u{1}index:\(connection.uuidString)"
    }

    private func writeEmptyPlaylist(named name: String) throws {
        try fm.createDirectory(at: paths.playlistsDir, withIntermediateDirectories: true)
        try PlaylistFile.emptyData.write(to: fileURL(.local(name)), options: .atomic)
    }

    private func readIndex(of connection: UUID) -> [RemotePlaylistInfo] {
        RemotePlaylistIndex.load(from: indexURL(of: connection)).sorted(by: RemotePlaylistInfo.isOrderedBefore)
    }

    private func saveIndex(of connection: UUID) {
        guard let section = remoteSections.first(where: { $0.connection == connection }) else { return }
        let playlists = section.playlists
        let url = indexURL(of: connection)
        queueWrite(key: Self.indexKey(connection), label: "the playlist index of \"\(section.name)\"") {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try RemotePlaylistIndex.data(of: playlists).write(to: url, options: .atomic)
        }
    }

    // MARK: Loading and saving

    /// Puts new content of a playlist that is in memory in place, and shows it if it is the active one.
    private func commit(_ playlist: Playlist, as id: PlaylistID) {
        loaded[Self.key(id)] = playlist
        if Self.key(id) == Self.key(activeID) { activePlaylist = playlist }
    }

    /// Takes what was read from a playlist's file into memory and returns the content. If the playlist has been
    /// put in memory in the meantime (the same file is read by the active load and the preload, one of them is
    /// first), that content stays: it may have been changed already.
    ///
    /// A remote playlist that has no usable file yet starts empty and flat, and is marked for reading from the server.
    private func adopt(_ result: PlaylistFile.LoadResult, id: PlaylistID, started: Date) -> Playlist {
        let key = Self.key(id)
        if let existing = loaded[key] { return existing }

        let playlist: Playlist
        switch result {
        case .loaded(let content, let legacyLastPlayed):
            playlist = content
            if let known = lastPlayedStore[key] {
                // What the file says is ignored, it is only the older versions' place for it.
                if content.position(of: known) == nil { lastPlayedStore[key] = nil }
            } else if let legacyLastPlayed {
                lastPlayedStore[key] = legacyLastPlayed
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.info("loaded '\(displayName(of: id))': \(content.trackCount) tracks in \(content.albums.count) albums, \(ms) ms")
        case .missing where id.isRemote:
            playlist = Playlist(albums: [], isFlat: true)
            lastPlayedStore[key] = nil
            updateRemoteInfo(id) { $0.synced = nil }
        case .missing:
            playlist = .empty
            lastPlayedStore[key] = nil
            Log.error("playlist file of '\(displayName(of: id))' is gone, starting empty")
        case .invalid(let reason):
            playlist = id.isRemote ? Playlist(albums: [], isFlat: true) : .empty
            lastPlayedStore[key] = nil
            Log.error("can't load '\(displayName(of: id))': \(reason)")
            if id.isRemote {
                // Only a copy: it is read from the server again.
                updateRemoteInfo(id) { $0.synced = nil }
                save(playlist, as: id)
            } else {
                quarantine(id)
            }
        }
        loaded[key] = playlist
        return playlist
    }

    /// Drops the current content and reads the active playlist's file (the other playlists follow, see
    /// `startPreload`). A load that is still running for a previously active playlist is cancelled and its
    /// result discarded.
    private func startLoad() {
        loadTask?.cancel()
        let id = activeID
        activePlaylist = .empty
        isLoading = true

        loadTask = Task {
            // Don't read a file that has a write queued: that would be stale.
            await flushWrites()
            guard !Task.isCancelled else { return }

            let url = fileURL(id)
            let started = Date()
            let result = await Task.detached(priority: .userInitiated) { PlaylistFile.load(from: url) }.value
            guard !Task.isCancelled else { return }

            activePlaylist = adopt(result, id: id, started: started)
            isLoading = false
            openCount += 1
            startPreload()
        }
    }

    /// The next playlist that isn't in memory yet (the active one is being read by `startLoad`).
    private func nextUnloadedID() -> PlaylistID? {
        ids.first { id in
            let key = Self.key(id)
            return loaded[key] == nil && !(isLoading && key == Self.key(activeID))
        }
    }

    /// Reads the playlists that aren't in memory yet, one after the other, in the background. Does nothing while one
    /// such run is going on; it picks the playlists by their current names, so one that is renamed or deleted
    /// meanwhile is handled.
    private func startPreload() {
        guard preloadTask == nil, nextUnloadedID() != nil else { return }
        isPreloading = true
        let started = Date()
        preloadTask = Task {
            while let id = nextUnloadedID() {
                await flushWrites()
                let url = fileURL(id)
                let begun = Date()
                let result = await Task.detached(priority: .utility) { PlaylistFile.load(from: url) }.value
                // Gone or taken over by the active load meanwhile: nothing to do (the loop moves on).
                guard exists(id), loaded[Self.key(id)] == nil else { continue }
                _ = adopt(result, id: id, started: begun)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.info("all \(loaded.count) playlists are in memory, \(ms) ms")
            isPreloading = false
            preloadTask = nil
        }
    }

    /// Moves an unusable playlist file aside (`name.json.broken`, ignored by `reload()`) and puts an empty
    /// playlist in its place, so the next save doesn't overwrite the original.
    private func quarantine(_ id: PlaylistID) {
        guard let name = id.localName else { return }
        let source = fileURL(id)
        var target = source.appendingPathExtension("broken")
        if fm.fileExists(atPath: target.path) {
            target = source.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
        }
        do {
            try fm.moveItem(at: source, to: target)
            Log.info("moved the unusable file to \(target.lastPathComponent)")
            try writeEmptyPlaylist(named: name)
        } catch {
            Log.error("can't set aside the unusable file of '\(name)': \(error.localizedDescription)")
        }
    }

    /// Queues a background write of the whole playlist file. If another save of the same
    /// file is queued behind this one by the time its turn comes, this one is skipped: the newer one writes it all.
    private func save(_ playlist: Playlist, as id: PlaylistID) {
        let url = fileURL(id)
        let remote = id.isRemote
        queueWrite(key: Self.key(id), label: "'\(displayName(of: id))'") {
            if remote {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try PlaylistFile.write(playlist, to: url)
        }
    }

    /// Queues `work` (a write of the file of `key`) behind the writes before it, off the main thread. It is skipped if
    /// another write of the same file is queued behind it by the time its turn comes, or the file was given up on
    /// meanwhile (`forget`).
    private func queueWrite(key: String, label: String, _ work: @escaping @Sendable () throws -> Void) {
        let serial = (saveSerial[key] ?? 0) + 1
        saveSerial[key] = serial
        let previous = writeTask
        pendingWrites += 1
        writeTask = Task {
            await previous?.value
            if saveSerial[key] == serial {
                let failure = await Task.detached(priority: .utility) { () -> String? in
                    do {
                        try work()
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let failure { Log.error("can't save \(label): \(failure)") }
            }
            pendingWrites -= 1
        }
    }

    private func reload() {
        let urls = (try? fm.contentsOfDirectory(
            at: paths.playlistsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []

        names = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func syncActiveToConfig() {
        guard exists(activeID) else { return }
        let text = activeID.text
        configStore.update { $0.activePlaylist = text }
    }
}
