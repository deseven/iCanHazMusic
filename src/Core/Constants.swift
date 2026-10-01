import Foundation

/// Central place for app-wide constants.
enum AppConstants {
    static let appName = "iCanHazMusic"
    static let appShortName = "iCHM"

    // MARK: - Window IDs

    static let mainWindowID = "main"
    static let aboutWindowID = "about"

    // MARK: - URLs

    static let websiteURL = URL(string: "https://icanhazapps.d7.wtf")!
    static let githubRepoURL = URL(string: "https://github.com/deseven/iCanHazMusic")!
    static let kofiURL = URL(string: "https://ko-fi.com/deseven")!
    static let redditURL = URL(string: "https://www.reddit.com/r/iCanHazApps")!
    static let discordURL = URL(string: "https://discord.gg/YE9KyTXRPt")!
    static let boxiconsURL = URL(string: "https://boxicons.com")!

    // MARK: - Album art

    /// Side of the square cover thumbnails kept in the cover cache: 2x the album block cover (`Layout.coverSize`,
    /// which derives from this). Changing it invalidates the cache (see `CoverStore`).
    static let coverThumbnailPixels = 112
}

/// Locations of everything the app stores on disk.
///
/// ```
/// ~/Library/Application Support/iCanHazMusic-dev/
///   config.json
///   playlists/{name}.json
///   .cache/covers.sqlite     album art thumbnails, safe to delete
/// ```
enum AppPaths {
    /// Name of the working directory inside Application Support.
    /// Hardcoded to the dev directory for now.
    static let workDirName = "iCanHazMusic-dev"

    static let workDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(workDirName, isDirectory: true)
    }()

    static let configURL = workDir.appendingPathComponent("config.json")
    static let playlistsDir = workDir.appendingPathComponent("playlists", isDirectory: true)
    /// Everything in here can be rebuilt, so it is always safe to delete.
    static let cacheDir = workDir.appendingPathComponent(".cache", isDirectory: true)
    static let coverCacheURL = cacheDir.appendingPathComponent("covers.sqlite")
}
