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
/// ~/Library/Application Support/iCanHazMusic-dev/     (or whatever `--workdir` says)
///   config.json
///   playlists/{name}.json
///   .cache/covers.sqlite     album art thumbnails, safe to delete
/// ```
struct AppPaths {
    /// Name of the default working directory inside Application Support.
    /// Hardcoded to the dev directory for now.
    static let workDirName = "iCanHazMusic-dev"
    /// Command line option that replaces the default working directory: `--workdir /path` or `--workdir=/path`.
    static let workDirOption = "--workdir"

    /// The paths the running app uses: the default working directory unless `--workdir` was given.
    static let current = AppPaths(workDir: resolveWorkDir(arguments: CommandLine.arguments))

    let workDir: URL
    let configURL: URL
    let playlistsDir: URL
    /// Everything in here can be rebuilt, so it is always safe to delete.
    let cacheDir: URL
    let coverCacheURL: URL

    init(workDir: URL) {
        self.workDir = workDir
        configURL = workDir.appendingPathComponent("config.json")
        playlistsDir = workDir.appendingPathComponent("playlists", isDirectory: true)
        cacheDir = workDir.appendingPathComponent(".cache", isDirectory: true)
        coverCacheURL = cacheDir.appendingPathComponent("covers.sqlite")
    }

    static var defaultWorkDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(workDirName, isDirectory: true)
    }

    /// The working directory for the given command line (`~` and relative paths are resolved).
    static func resolveWorkDir(arguments: [String]) -> URL {
        var value: String?
        var i = 1
        while i < arguments.count {
            let argument = arguments[i]
            if argument == workDirOption, i + 1 < arguments.count {
                value = arguments[i + 1]
                i += 1
            } else if argument.hasPrefix(workDirOption + "=") {
                value = String(argument.dropFirst(workDirOption.count + 1))
            }
            i += 1
        }
        guard let value, !value.isEmpty else { return defaultWorkDir }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
}
