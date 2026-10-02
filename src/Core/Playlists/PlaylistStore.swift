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
/// Only the active playlist is kept in memory (`activePlaylist`): it's loaded from its file when it becomes
/// active and dropped when another one is selected or it is deleted. The one exception is the playlist that
/// playback runs from (`playingName`): while something is playing or paused, it stays in memory even when
/// the user browses another playlist, and is taken back as is (no reload) when selected again.
/// The file format is `PlaylistFile`.
/// Loading is asynchronous (`isLoading`); content changes are written back in the background.
@MainActor
@Observable
final class PlaylistStore {
    static let shared = PlaylistStore()

    /// Playlist names, sorted alphabetically.
    private(set) var names: [String] = []
    private(set) var activeName: String = ""

    /// Content of the active playlist. Empty while `isLoading`.
    private(set) var activePlaylist: Playlist = .empty
    /// The active playlist is being read from disk. It can't be modified until that's done.
    private(set) var isLoading = false

    /// The playlist playback runs from, if any (set through `playbackStarted`/`playbackEnded`).
    private(set) var playingName: String?
    /// The playing playlist while it isn't the active one.
    @ObservationIgnored private var background: (name: String, playlist: Playlist)?

    @ObservationIgnored private let fm = FileManager.default
    @ObservationIgnored private let configStore = ConfigStore.shared
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Writes are chained so they hit the disk in the order they were requested.
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWrites = 0

    private static let maxNameBytes = 200

    private init() {
        do {
            try fm.createDirectory(at: AppPaths.playlistsDir, withIntermediateDirectories: true)
        } catch {
            Log.error("can't create \(AppPaths.playlistsDir.path): \(error.localizedDescription)")
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

    /// Content of the playlist playback runs from, whether it's the active one or kept in the background.
    var playingPlaylist: Playlist? {
        guard let playing = playingName else { return nil }
        if Self.key(playing) == Self.key(activeName) { return isLoading ? nil : activePlaylist }
        if let background, Self.key(background.name) == Self.key(playing) { return background.playlist }
        return nil
    }

    /// Playback has started from the active playlist: keep it in memory until `playbackEnded`.
    func playbackStarted() {
        guard !isLoading, !activeName.isEmpty else { return }
        playingName = activeName
        if let background, Self.key(background.name) != Self.key(activeName) { self.background = nil }
    }

    func playbackEnded() {
        playingName = nil
        background = nil
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

        activePlaylist = updated
        save(updated, as: match)
        if let playing = playingName, Self.key(playing) == Self.key(match) {
            PlaybackState.shared.playlistDidChange()
        }
    }

    /// Waits until everything queued by `save` is on disk.
    func flushWrites() async {
        await writeTask?.value
    }

    func setActive(_ name: String) {
        guard let match = existingName(matching: name) else { return }
        let changed = Self.key(match) != Self.key(activeName)
        if changed, let playing = playingName, Self.key(playing) == Self.key(activeName), !isLoading {
            background = (activeName, activePlaylist)   // keep it for the playback
        }
        activeName = match
        syncActiveToConfig()
        guard changed else { return }

        if let held = background, Self.key(held.name) == Self.key(match) {
            loadTask?.cancel()
            activePlaylist = held.playlist
            isLoading = false
            background = nil
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
                let temp = AppPaths.playlistsDir.appendingPathComponent(".rename-\(UUID().uuidString)")
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
        if let playing = playingName, Self.key(playing) == Self.key(current) { playingName = finalName }
        if let held = background, Self.key(held.name) == Self.key(current) {
            background = (finalName, held.playlist)
        }
        if wasActive {
            // Same playlist under a new name: keep the loaded content.
            activeName = finalName
            syncActiveToConfig()
            if isLoading { startLoad() }   // the file being read has just moved
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
            PlaybackState.shared.stop()   // also releases the playlist held for the playback
        }

        let wasActive = Self.key(activeName) == Self.key(current)
        reload()
        if wasActive, let first = names.first { setActive(first) }   // unloads the deleted one
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
        AppPaths.playlistsDir.appendingPathComponent(name + ".json")
    }

    private func writeEmptyPlaylist(named name: String) throws {
        try fm.createDirectory(at: AppPaths.playlistsDir, withIntermediateDirectories: true)
        try PlaylistFile.emptyData.write(to: fileURL(name), options: .atomic)
    }

    // MARK: Loading and saving

    /// Drops the current content and reads the active playlist's file. A load that is still running
    /// for a previously active playlist is cancelled and its result discarded.
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

            switch result {
            case .loaded(let playlist):
                activePlaylist = playlist
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Log.info("loaded '\(name)': \(playlist.trackCount) tracks in \(playlist.albums.count) albums, \(ms) ms")
            case .missing:
                Log.error("playlist file of '\(name)' is gone, starting empty")
            case .invalid(let reason):
                Log.error("can't load '\(name)': \(reason)")
                quarantine(name)
            }
            isLoading = false
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

    /// Queues a background write of the whole playlist file.
    private func save(_ playlist: Playlist, as name: String) {
        let url = fileURL(name)
        let previous = writeTask
        pendingWrites += 1
        writeTask = Task {
            await previous?.value
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try PlaylistFile.write(playlist, to: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure { Log.error("can't save '\(name)': \(failure)") }
            pendingWrites -= 1
        }
    }

    private func reload() {
        let urls = (try? fm.contentsOfDirectory(
            at: AppPaths.playlistsDir,
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
