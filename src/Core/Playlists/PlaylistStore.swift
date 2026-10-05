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

/// The set of playlists living in `playlists/*.json` and the currently active one.
///
/// Every playlist is kept in memory (search needs them all), but only the active one is shown: `activePlaylist`
/// is what the UI gets, the others are not pushed anywhere. At launch the active playlist is read first, then the
/// others one after the other in the background (`isPreloading`); a playlist that is selected before its turn is
/// read at once. A playlist leaves memory only when it is deleted. `playingName` is the playlist playback runs from,
/// which is not necessarily the active one.
/// The file format is `PlaylistFile`.
/// Loading is asynchronous (`isLoading`); content changes are written back in the background.
@MainActor
@Observable
final class PlaylistStore {
    static let shared = PlaylistStore(paths: .current, configStore: .shared)

    /// Playlist names, sorted alphabetically.
    private(set) var names: [String] = []
    private(set) var activeName: String = ""

    /// Content of the active playlist. Empty while `isLoading`.
    private(set) var activePlaylist: Playlist = .empty
    /// The active playlist is being read from disk. It can't be modified until that's done.
    private(set) var isLoading = false
    /// The other playlists are being read from disk (after the active one, in the background).
    private(set) var isPreloading = false
    /// Counts how often a playlist has been opened: became the active one with its content in place (loaded from
    /// disk, or already in memory). The view reacts to this by showing `lastPlayedRow`.
    private(set) var openCount = 0

    /// Album blocks of grouped playlists show the album art (it is cached either way). Persisted in the config.
    var displayAlbumArt = true {
        didSet {
            guard displayAlbumArt != oldValue else { return }
            configStore.update { $0.playlist.displayAlbumArt = displayAlbumArt }
        }
    }

    /// Files whose tags are read at the same time on an import; `ConfigLimits.tagParsingConcurrencyAuto` (0) =
    /// automatic. Persisted in the config.
    var tagParsingConcurrency = ConfigLimits.tagParsingConcurrencyAuto {
        didSet {
            guard tagParsingConcurrency != oldValue else { return }
            configStore.update { $0.playlist.tagParsingConcurrency = tagParsingConcurrency }
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
    private(set) var playingName: String?
    /// Every playlist that has been read (key: `key(name)`), the active one included once it is loaded.
    @ObservationIgnored private var loaded: [String: Playlist] = [:]
    /// The playback running from this store's playlists (set by `PlaybackState` itself): told when the playing
    /// playlist grows or is deleted.
    @ObservationIgnored weak var playback: PlaybackState?

    @ObservationIgnored private let fm = FileManager.default
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    /// Writes are chained so they hit the disk in the order they were requested.
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWrites = 0
    /// Number of the newest save queued for each file (key: `key(name)`): older ones still waiting in the chain
    /// are covered by it and skipped.
    @ObservationIgnored private var saveSerial: [String: Int] = [:]
    /// The `last_played` of every playlist that has been loaded (key: `key(name)`); a playlist's file is only
    /// ever written while it is in memory, so what is stored here is what its file gets.
    @ObservationIgnored private var lastPlayedByKey: [String: TrackID] = [:]
    /// The row of the active playlist that `reveal` wants shown when the view reacts to the opening.
    @ObservationIgnored private var pendingReveal: Int?

    private static let maxNameBytes = 200

    init(paths: AppPaths, configStore: ConfigStore) {
        self.paths = paths
        self.configStore = configStore
        displayAlbumArt = configStore.config.playlist.displayAlbumArt
        tagParsingConcurrency = configStore.config.playlist.tagParsingConcurrency
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

        // Fall back to the first playlist if the configured one is gone.
        if let match = existingName(matching: configStore.config.activePlaylist) {
            activeName = match
        } else if let first = names.first {
            Log.info("active playlist '\(configStore.config.activePlaylist)' not found, switching to '\(first)'")
            activeName = first
        }
        syncActiveToConfig()
        if !activeName.isEmpty { startLoad() }
    }

    // MARK: - Queries

    func exists(_ name: String) -> Bool {
        existingName(matching: name) != nil
    }

    /// Whether a playlist write is still queued or running (the app must not quit yet).
    var hasPendingWrites: Bool { pendingWrites > 0 }

    /// Content of the playlist playback runs from, whether it's the active one or not.
    var playingPlaylist: Playlist? {
        guard let playing = playingName else { return nil }
        return loaded[Self.key(playing)]
    }

    /// The content of a playlist that is in memory (the active one while it is still being read isn't).
    func playlist(named name: String) -> Playlist? {
        loaded[Self.key(name)]
    }

    /// The playlists that are in memory, in the order of `names`.
    var loadedPlaylists: [(name: String, playlist: Playlist)] {
        names.compactMap { name in loaded[Self.key(name)].map { (name, $0) } }
    }

    /// The ID of the track that was started last in this playlist (it is in memory and has that track), if any.
    func lastPlayed(in name: String) -> TrackID? {
        let key = Self.key(name)
        guard loaded[key] != nil else { return nil }
        return lastPlayedByKey[key]
    }

    /// The row of the active playlist's last played track (see `setLastPlayed`), if it is loaded and has it.
    var lastPlayedRow: Int? {
        guard !isLoading, let id = lastPlayedByKey[Self.key(activeName)] else { return nil }
        return activePlaylist.row(of: id)
    }

    /// Playback runs from the playlist that is currently shown (and it is loaded).
    var playingIsActive: Bool {
        guard let playing = playingName, !isLoading else { return false }
        return Self.key(playing) == Self.key(activeName)
    }

    /// Playback has started from the active playlist.
    func playbackStarted() {
        guard !isLoading, !activeName.isEmpty else { return }
        playingName = activeName
    }

    /// Playback has started from another playlist than the active one (a queued track): it is in memory.
    func playbackStarted(in name: String) {
        guard let match = existingName(matching: name), loaded[Self.key(match)] != nil else { return }
        playingName = match
    }

    func playbackEnded() {
        playingName = nil
    }

    func showQueue() {
        isQueueShown = true
    }

    func hideQueue() {
        isQueueShown = false
    }

    // MARK: - Mutations

    /// Adds albums at the end of the active playlist and stores it. Ignored for any other playlist and
    /// while the active one is still loading.
    func append(_ albums: [Album], to name: String) async {
        guard !albums.isEmpty, !isLoading, let match = existingName(matching: name),
              Self.key(match) == Self.key(activeName) else { return }

        let current = activePlaylist
        let updated = await Task.detached(priority: .userInitiated) { current.appending(albums) }.value
        // Something else replaced the content in the meantime (can't happen behind the modal import sheet).
        guard activePlaylist === current else { return }

        commit(updated, as: match)
        save(updated, as: match)
        if let playing = playingName, Self.key(playing) == Self.key(match) {
            playback?.playlistDidChange()
        }
    }

    /// Removes these tracks from the active playlist (see `Playlist.trackIDs`). Playback stops if its track is
    /// among them.
    func remove(ids removed: Set<TrackID>, from name: String) async {
        guard !removed.isEmpty else { return }
        guard await replaceActive(name, { $0.removing(ids: removed) }), let match = existingName(matching: name) else { return }
        playback?.queue.remove(ids: removed, fromPlaylist: match)
    }

    /// Takes over freshly read tags into the active playlist and regroups it (see `Playlist.updatingTags`).
    func applyTags(_ results: [TagReadResult], to name: String) async {
        guard !results.isEmpty else { return }
        await replaceActive(name) { $0.updatingTags(from: results) }
    }

    /// Turns the album grouping of the active playlist off or on ("Don't group by albums") and stores it.
    func setFlat(_ flat: Bool) async {
        guard !isLoading, activePlaylist.isFlat != flat else { return }
        await replaceActive(activeName) { $0.settingFlat(flat) }
    }

    /// Records what playback found out about the file it plays: the real duration and format. Applied to the
    /// playlist playback runs from (shown or not), if it still has that track.
    func updateTrack(id: TrackID, duration: TimeInterval, codec: String) {
        guard let playing = playingName, let current = playingPlaylist,
              let updated = current.replacingTrack(id: id, duration: duration, codec: codec) else { return }
        commit(updated, as: playing)
        save(updated, as: playing)
    }

    /// Playback has started this track of the playlist it runs from: it is that playlist's last played one, which
    /// is stored with it (and shown again when the playlist is opened).
    func setLastPlayed(_ id: TrackID) {
        guard let playing = playingName, let playlist = playingPlaylist, playlist.position(of: id) != nil else { return }
        let key = Self.key(playing)
        guard lastPlayedByKey[key] != id else { return }
        lastPlayedByKey[key] = id
        save(playlist, as: playing)
    }

    /// Waits until everything queued by `save` is on disk.
    func flushWrites() async {
        await writeTask?.value
    }

    /// Opens a playlist that is in memory and has the view show one of its tracks (or the header of its album with
    /// `wholeAlbum`) instead of the last played one: see `takeReveal`. Does nothing if the playlist or the track
    /// isn't there.
    func reveal(trackID: TrackID, inPlaylist name: String, wholeAlbum: Bool = false) {
        guard let match = existingName(matching: name), let playlist = loaded[Self.key(match)],
              let pos = playlist.position(of: trackID) else { return }
        let row = wholeAlbum && !playlist.isFlat ? playlist.headerRow[pos.album] : playlist.row(of: trackID)
        let changed = Self.key(match) != Self.key(activeName)
        setActive(match)
        pendingReveal = row
        if !changed { openCount += 1 }   // the view has to be pointed at the row though nothing was opened
    }

    /// The row `reveal` asked for, once (read when the view reacts to `openCount`).
    func takeReveal() -> Int? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    func setActive(_ name: String) {
        guard let match = existingName(matching: name) else { return }
        let changed = Self.key(match) != Self.key(activeName)
        if isQueueShown {
            // Back from the queue: the view is rebuilt, so it has to be pointed at the track again.
            isQueueShown = false
            if !changed { openCount += 1 }
        }
        activeName = match
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
    }

    /// Creates a new empty playlist and makes it active. Returns the final name.
    @discardableResult
    func create(named rawName: String) throws -> String {
        let name = try Self.validate(rawName)
        guard !exists(name) else { throw PlaylistError.alreadyExists(name) }

        do {
            try writeEmptyPlaylist(named: name)
        } catch {
            throw PlaylistError.io(error)
        }
        reload()
        setActive(name)
        return name
    }

    func rename(_ oldName: String, to rawName: String) async throws {
        // A queued write would otherwise recreate the old file.
        await flushWrites()
        let newName = try Self.validate(rawName)
        guard let current = existingName(matching: oldName) else { throw PlaylistError.notFound(oldName) }
        guard newName != current else { return }

        let sameFile = Self.key(newName) == Self.key(current)
        if !sameFile, exists(newName) { throw PlaylistError.alreadyExists(newName) }

        do {
            if sameFile {
                // Only the letter case differs; on a case-insensitive volume that's the same file,
                // so go through a temporary name.
                let temp = paths.playlistsDir.appendingPathComponent(".rename-\(UUID().uuidString)")
                try fm.moveItem(at: fileURL(current), to: temp)
                try fm.moveItem(at: temp, to: fileURL(newName))
            } else {
                try fm.moveItem(at: fileURL(current), to: fileURL(newName))
            }
        } catch {
            throw PlaylistError.io(error)
        }

        let wasActive = Self.key(activeName) == Self.key(current)
        reload()
        let finalName = existingName(matching: newName) ?? newName
        if let last = lastPlayedByKey.removeValue(forKey: Self.key(current)) { lastPlayedByKey[Self.key(finalName)] = last }
        if let playing = playingName, Self.key(playing) == Self.key(current) { playingName = finalName }
        playback?.queue.renamePlaylist(from: current, to: finalName)
        if let content = loaded.removeValue(forKey: Self.key(current)) { loaded[Self.key(finalName)] = content }
        startPreload()   // a read of the old file may have come back empty-handed
        if wasActive {
            // Same playlist under a new name: keep the loaded content.
            activeName = finalName
            syncActiveToConfig()
            if isLoading {
                startLoad()   // the file being read has just moved; the load counts as the opening
            } else {
                openCount += 1   // the view is rebuilt for the new name, so it has to be pointed at the track again
            }
        }
    }

    func delete(_ name: String) async throws {
        await flushWrites()
        guard let current = existingName(matching: name) else { throw PlaylistError.notFound(name) }
        guard names.count > 1 else { throw PlaylistError.lastPlaylist }

        do {
            try fm.removeItem(at: fileURL(current))
        } catch {
            throw PlaylistError.io(error)
        }

        if let playing = playingName, Self.key(playing) == Self.key(current) {
            playback?.halt()   // also releases the playlist held for the playback; the queue is kept (minus this playlist's tracks)
        }

        playback?.queue.removeAll(inPlaylist: current)
        lastPlayedByKey[Self.key(current)] = nil
        loaded[Self.key(current)] = nil
        let wasActive = Self.key(activeName) == Self.key(current)
        reload()
        if wasActive, let first = names.first { setActive(first) }
    }

    /// Replaces the content of the active playlist with `transform` of it (run off the main thread), stores it
    /// and tells playback, which has to find its track again by its ID. A last played track that is gone is forgotten.
    /// Ignored for any other playlist and while the active one is still loading.
    /// Returns whether the content was replaced.
    @discardableResult
    private func replaceActive(_ name: String, _ transform: @escaping (Playlist) -> Playlist) async -> Bool {
        guard !isLoading, let match = existingName(matching: name), Self.key(match) == Self.key(activeName) else { return false }

        let current = activePlaylist
        let updated = await Task.detached(priority: .userInitiated) { transform(current) }.value
        guard activePlaylist === current else { return false }   // something else replaced the content in the meantime

        commit(updated, as: match)
        let key = Self.key(match)
        if let last = lastPlayedByKey[key], updated.position(of: last) == nil { lastPlayedByKey[key] = nil }
        save(updated, as: match)
        if let playing = playingName, Self.key(playing) == key {
            playback?.playlistWasReplaced(from: current, to: updated)
        } else {
            playback?.playlistDidChange()   // a queued track may be in it, at another place now
        }
        return true
    }

    // MARK: - Validation

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

    // MARK: - Internals

    /// APFS/HFS+ ignore letter case and Unicode normalization form in file names, so do we.
    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func existingName(matching name: String) -> String? {
        let k = Self.key(name)
        return names.first { Self.key($0) == k }
    }

    private func fileURL(_ name: String) -> URL {
        paths.playlistsDir.appendingPathComponent(name + ".json")
    }

    private func writeEmptyPlaylist(named name: String) throws {
        try fm.createDirectory(at: paths.playlistsDir, withIntermediateDirectories: true)
        try PlaylistFile.emptyData.write(to: fileURL(name), options: .atomic)
    }

    // MARK: Loading and saving

    /// Puts new content of a playlist that is in memory in place, and shows it if it is the active one.
    private func commit(_ playlist: Playlist, as name: String) {
        loaded[Self.key(name)] = playlist
        if Self.key(name) == Self.key(activeName) { activePlaylist = playlist }
    }

    /// Takes what was read from a playlist's file into memory and returns the content. If the playlist has been
    /// put in memory in the meantime (the same file is read by the active load and the preload, one of them is
    /// first), that content stays: it may have been changed already.
    private func adopt(_ result: PlaylistFile.LoadResult, name: String, started: Date) -> Playlist {
        let key = Self.key(name)
        if let existing = loaded[key] { return existing }

        let playlist: Playlist
        switch result {
        case .loaded(let content, let lastPlayed):
            playlist = content
            lastPlayedByKey[key] = lastPlayed
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.info("loaded '\(name)': \(content.trackCount) tracks in \(content.albums.count) albums, \(ms) ms")
        case .missing:
            playlist = .empty
            lastPlayedByKey[key] = nil
            Log.error("playlist file of '\(name)' is gone, starting empty")
        case .invalid(let reason):
            playlist = .empty
            lastPlayedByKey[key] = nil
            Log.error("can't load '\(name)': \(reason)")
            quarantine(name)
        }
        loaded[key] = playlist
        return playlist
    }

    /// Drops the current content and reads the active playlist's file (the other playlists follow, see
    /// `startPreload`). A load that is still running for a previously active playlist is cancelled and its
    /// result discarded.
    private func startLoad() {
        loadTask?.cancel()
        let name = activeName
        activePlaylist = .empty
        isLoading = true

        loadTask = Task {
            // Don't read a file that has a write queued: that would be stale.
            await flushWrites()
            guard !Task.isCancelled else { return }

            let url = fileURL(name)
            let started = Date()
            let result = await Task.detached(priority: .userInitiated) { PlaylistFile.load(from: url) }.value
            guard !Task.isCancelled else { return }

            activePlaylist = adopt(result, name: name, started: started)
            isLoading = false
            openCount += 1
            startPreload()
        }
    }

    /// The next playlist that isn't in memory yet (the active one is being read by `startLoad`).
    private func nextUnloadedName() -> String? {
        names.first { name in
            let key = Self.key(name)
            return loaded[key] == nil && !(isLoading && key == Self.key(activeName))
        }
    }

    /// Reads the playlists that aren't in memory yet, one after the other, in the background. Does nothing while one
    /// such run is going on; it picks the playlists by their current names, so one that is renamed or deleted
    /// meanwhile is handled.
    private func startPreload() {
        guard preloadTask == nil, nextUnloadedName() != nil else { return }
        isPreloading = true
        let started = Date()
        preloadTask = Task {
            while let name = nextUnloadedName() {
                await flushWrites()
                let url = fileURL(name)
                let begun = Date()
                let result = await Task.detached(priority: .utility) { PlaylistFile.load(from: url) }.value
                // Gone or taken over by the active load meanwhile: nothing to do (the loop moves on).
                guard names.contains(name), loaded[Self.key(name)] == nil else { continue }
                _ = adopt(result, name: name, started: begun)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.info("all \(loaded.count) playlists are in memory, \(ms) ms")
            isPreloading = false
            preloadTask = nil
        }
    }

    /// Moves an unusable playlist file aside (`name.json.broken`, ignored by `reload()`) and puts an empty
    /// playlist in its place, so the next save doesn't overwrite the original.
    private func quarantine(_ name: String) {
        let source = fileURL(name)
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

    /// Queues a background write of the whole playlist file (with its `last_played`). If another save of the same
    /// file is queued behind this one by the time its turn comes, this one is skipped: the newer one writes it all.
    private func save(_ playlist: Playlist, as name: String) {
        let url = fileURL(name)
        let key = Self.key(name)
        let lastPlayed = lastPlayedByKey[key]
        let serial = (saveSerial[key] ?? 0) + 1
        saveSerial[key] = serial
        let previous = writeTask
        pendingWrites += 1
        writeTask = Task {
            await previous?.value
            if saveSerial[key] == serial {
                let failure = await Task.detached(priority: .utility) { () -> String? in
                    do {
                        try PlaylistFile.write(playlist, lastPlayed: lastPlayed, to: url)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let failure { Log.error("can't save '\(name)': \(failure)") }
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
        guard !activeName.isEmpty else { return }
        configStore.update { $0.activePlaylist = activeName }
    }
}
