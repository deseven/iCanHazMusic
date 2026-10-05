// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Central place for app-wide constants.
enum AppConstants {
    static let appName = "iCanHazMusic"
    static let appShortName = "iCHM"

    /// `CFBundleShortVersionString` of the running bundle ("0" when there is none, as in tests and plain `swift build`).
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    /// What every HTTP request of the app (Last.fm, LRCLIB) identifies itself with.
    static let userAgent = "\(appName)/\(appVersion)"

    // MARK: - Window IDs

    static let mainWindowID = "main"
    static let aboutWindowID = "about"
    static let preferencesWindowID = "preferences"

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
/// ~/Library/Application Support/iCanHazMusic/     (or whatever `--workdir` says)
///   config.json
///   app.log                  the log of the current run (stdout is duplicated into it), rewritten on every start
///   playlists/{name}.json
///   .cache/covers.sqlite     album art thumbnails, safe to delete
///   .cache/lyrics.sqlite     lyrics (from the tags and from LRCLIB); the embedded ones come back with Reload Tag(s)
/// ```
struct AppPaths {
    /// Name of the default working directory inside Application Support (the previous version used the same one,
    /// see `LegacyMigration`).
    static let workDirName = "iCanHazMusic"
    /// Command line option that replaces the default working directory: `--workdir /path` or `--workdir=/path`.
    static let workDirOption = "--workdir"

    /// The paths the running app uses: the default working directory unless `--workdir` was given.
    static let current = AppPaths(workDir: resolveWorkDir(arguments: CommandLine.arguments))

    let workDir: URL
    let configURL: URL
    let logURL: URL
    let playlistsDir: URL
    /// Everything in here can be rebuilt, so it is always safe to delete.
    let cacheDir: URL
    let coverCacheURL: URL
    let lyricsCacheURL: URL

    init(workDir: URL) {
        self.workDir = workDir
        configURL = workDir.appendingPathComponent("config.json")
        logURL = workDir.appendingPathComponent("app.log")
        playlistsDir = workDir.appendingPathComponent("playlists", isDirectory: true)
        cacheDir = workDir.appendingPathComponent(".cache", isDirectory: true)
        coverCacheURL = cacheDir.appendingPathComponent("covers.sqlite")
        lyricsCacheURL = cacheDir.appendingPathComponent("lyrics.sqlite")
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
