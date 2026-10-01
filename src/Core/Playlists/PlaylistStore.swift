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
/// The playlist file format isn't defined yet; a playlist is just an (empty) JSON object.
/// Playlist *content* only lives in memory for now (see `playlist(named:)`), nothing is stored.
@MainActor
@Observable
final class PlaylistStore {
    static let shared = PlaylistStore()

    /// Playlist names, sorted alphabetically.
    private(set) var names: [String] = []
    private(set) var activeName: String = ""

    /// In-memory content per playlist, keyed by `key(name)`. Missing entry = empty playlist.
    private var contents: [String: Playlist] = [:]

    @ObservationIgnored private let fm = FileManager.default
    @ObservationIgnored private let configStore = ConfigStore.shared

    private static let maxNameBytes = 200
    private static let emptyPlaylistData = Data("{}\n".utf8)

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
    }

    // MARK: - Queries

    func exists(_ name: String) -> Bool {
        existingName(matching: name) != nil
    }

    func playlist(named name: String) -> Playlist {
        contents[Self.key(name)] ?? .empty
    }

    // MARK: - Mutations

    /// Adds albums at the end of a playlist.
    func append(_ albums: [Album], to name: String) {
        guard !albums.isEmpty, let match = existingName(matching: name) else { return }
        contents[Self.key(match)] = playlist(named: match).appending(albums)
    }

    func setActive(_ name: String) {
        guard let match = existingName(matching: name) else { return }
        activeName = match
        syncActiveToConfig()
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

    func rename(_ oldName: String, to rawName: String) throws {
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

        if let content = contents.removeValue(forKey: Self.key(current)) {
            contents[Self.key(newName)] = content
        }

        let wasActive = Self.key(activeName) == Self.key(current)
        reload()
        if wasActive { setActive(newName) }
    }

    func delete(_ name: String) throws {
        guard let current = existingName(matching: name) else { throw PlaylistError.notFound(name) }
        guard names.count > 1 else { throw PlaylistError.lastPlaylist }

        do {
            try fm.removeItem(at: fileURL(current))
        } catch {
            throw PlaylistError.io(error)
        }

        contents.removeValue(forKey: Self.key(current))

        let wasActive = Self.key(activeName) == Self.key(current)
        reload()
        if wasActive, let first = names.first { setActive(first) }
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
        try Self.emptyPlaylistData.write(to: fileURL(name), options: .atomic)
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
