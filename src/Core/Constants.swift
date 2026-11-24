// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Central place for app-wide constants.
enum AppConstants {
    static let appName = "iCanHazMusic"
    static let appShortName = "iCHM"

    /// `CFBundleShortVersionString` of the running bundle ("0" when there is none, as in tests and plain `swift build`).
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    /// What every HTTP request of the app (scrobbling services, LRCLIB, updates) identifies itself with.
    /// MetaBrainz hosts additionally get `contactURL`, see `userAgent(for:)`.
    static let userAgent = "\(appName)/\(appVersion)"

    /// Where the maintainer can be reached. MetaBrainz (MusicBrainz, ListenBrainz, ...) requires a way to contact the
    /// author of an app in its `User-Agent`; it is sent to their hosts only.
    static let contactURL = "https://d7.wtf/contact"

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
///   .cache/last_played.json  the track that was started last in each playlist (`LastPlayedStore`), shown again when the playlist is opened; losing it costs nothing
///   .cache/covers.sqlite     album art thumbnails, safe to delete (Subsonic albums get theirs when they are shown or played)
///   .cache/lyrics.sqlite     lyrics (from the tags and from LRCLIB); the embedded ones come back with Reload Tag(s)
///   .cache/waveforms.sqlite  what the visual seekbar styles show about the tracks played with them (loudness, spectrum, sections), made again on demand
///   .cache/subsonic/{connection id}/
///       downloads/           the downloaded files of Subsonic songs (`SubsonicDownloads`): kept up to the connection's cache size, or (no cache) deleted as soon as nothing needs them and at launch and quit
///       playlists/           the playlists of the server as they were seen last (`RemotePlaylistIndex`), what is shown until the server answers
///       covers/              the covers (1200 px) of the albums that were played or shown, one file per album (`SubsonicCoverCache`, `SubsonicCovers`), never pruned
///   (the directory of a connection is deleted with the connection)
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
    let lastPlayedURL: URL
    let coverCacheURL: URL
    let lyricsCacheURL: URL
    let waveformCacheURL: URL
    /// What is kept of the Subsonic connections, a directory per connection (`subsonicDir(of:)`).
    let subsonicCacheDir: URL

    static let subsonicDownloadsDirName = "downloads"
    static let subsonicPlaylistsDirName = "playlists"
    static let subsonicCoversDirName = "covers"

    /// What is kept of one connection (`root`: `subsonicCacheDir`). The name is the UUID as Foundation writes it.
    static func subsonicDir(of connection: UUID, in root: URL) -> URL {
        root.appendingPathComponent(connection.uuidString, isDirectory: true)
    }

    /// The cached playlists of a connection.
    func subsonicPlaylistsDir(of connection: UUID) -> URL {
        Self.subsonicDir(of: connection, in: subsonicCacheDir)
            .appendingPathComponent(Self.subsonicPlaylistsDirName, isDirectory: true)
    }

    init(workDir: URL) {
        self.workDir = workDir
        configURL = workDir.appendingPathComponent("config.json")
        logURL = workDir.appendingPathComponent("app.log")
        playlistsDir = workDir.appendingPathComponent("playlists", isDirectory: true)
        cacheDir = workDir.appendingPathComponent(".cache", isDirectory: true)
        lastPlayedURL = cacheDir.appendingPathComponent("last_played.json")
        coverCacheURL = cacheDir.appendingPathComponent("covers.sqlite")
        lyricsCacheURL = cacheDir.appendingPathComponent("lyrics.sqlite")
        waveformCacheURL = cacheDir.appendingPathComponent("waveforms.sqlite")
        subsonicCacheDir = cacheDir.appendingPathComponent("subsonic", isDirectory: true)
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
