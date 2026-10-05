// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Migration from the previous (PureBasic) version of the player, which kept `settings.json` and
/// `current_state.json` in the same directory the app uses now. Everything here is best effort: whatever can't be
/// read or has no counterpart is skipped.
///
/// The flow (the UI part is `MigrationActions`): the old data is recognized (`isNeeded`), the user confirms, the app
/// starts as usual (fresh config and `main` playlist), the settings are put into the config (`LegacySettings.apply`),
/// the tracks of the old playlist are read again into `main`, and finally everything that isn't ours is removed
/// (`cleanUp`).
enum LegacyMigration {
    static let settingsFileName = "settings.json"
    static let stateFileName = "current_state.json"

    /// There is no `config.json` (this is not a directory of this version) but a `settings.json` of the old one.
    static func isNeeded(paths: AppPaths) -> Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: paths.configURL.path)
            && fm.fileExists(atPath: paths.workDir.appendingPathComponent(settingsFileName).path)
    }

    /// What is taken over.
    struct Plan {
        /// `nil` if `settings.json` couldn't be read.
        var settings: LegacySettings?
        /// Audio files of the old playlist in its order (duplicates kept).
        var files: [URL]
    }

    /// Reads the old files. Missing or broken ones give nothing (no settings / no files).
    static func loadPlan(paths: AppPaths) -> Plan {
        let settingsData = try? Data(contentsOf: paths.workDir.appendingPathComponent(settingsFileName))
        let stateData = try? Data(contentsOf: paths.workDir.appendingPathComponent(stateFileName))
        let settings = settingsData.flatMap(LegacySettings.init(json:))
        if settings == nil { Log.error("migration: \(settingsFileName) can't be read, its settings are skipped") }
        let files = stateData.map(parseState) ?? []
        Log.info("migration: \(files.count) tracks in \(stateFileName)")
        return Plan(settings: settings, files: files)
    }

    /// The files of `current_state.json`: an array of rows with a `file` path. Rows that are album headers
    /// (`isAlbum` set) or have no path are skipped; the order and duplicates are kept.
    static func parseState(_ data: Data) -> [URL] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var files: [URL] = []
        for row in rows {
            if let isAlbum = row["isAlbum"], !"\(isAlbum)".isEmpty { continue }
            guard let path = row["file"] as? String, !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: false)
            if AudioFileGatherer.isSupported(url) { files.append(url) }
        }
        return files
    }

    /// Removes everything in the working directory except what belongs to this version (`config.json`, `app.log`,
    /// `.cache`, `playlists`). Irreversible; failures are logged and skipped.
    static func cleanUp(paths: AppPaths) {
        let fm = FileManager.default
        let keep: Set<String> = [paths.configURL.lastPathComponent, paths.logURL.lastPathComponent,
                                 paths.cacheDir.lastPathComponent, paths.playlistsDir.lastPathComponent]
        guard let items = try? fm.contentsOfDirectory(
            at: paths.workDir, includingPropertiesForKeys: nil, options: []
        ) else {
            Log.error("migration: can't list \(paths.workDir.path)")
            return
        }
        var removed = 0
        for item in items where !keep.contains(item.lastPathComponent) {
            do {
                try fm.removeItem(at: item)
                removed += 1
            } catch {
                Log.error("migration: can't remove \(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        Log.info("migration: removed \(removed) old item(s) from \(paths.workDir.path)")
    }
}

/// The values of the old `settings.json` that have a counterpart in this version.
///
/// Ignored on purpose: the column widths and `last_played_track_id` (IDs differ now), `fullscreen`, `volume` and the
/// web server.
///
/// TODO later (no counterpart yet, so they're dropped for now): `playback.stop_at_queue_end`,
/// `playback.playback_order`.
struct LegacySettings: Equatable {
    var lastFMSession: String?
    var lastFMUser: String?
    /// `use_genius`: lyrics were looked up online; the counterpart is LRCLIB.
    var lookUpLyrics: Bool?
    /// `use_terminal_notifier`: playback notifications were shown (through terminal-notifier); the counterpart is
    /// the playback notifications switch, which sends the system's own.
    var playbackNotifications: Bool?
    var cursorFollowsPlayback: Bool?
    var playbackFollowsCursor: Bool?
    /// `playlist.dont_group_by_albums`; applies to the `main` playlist, not to the config.
    var dontGroupByAlbums: Bool?
    /// Hotkey strings (`toggle_shortcut` = play/pause, `find_shortcut` = search, ...), already in the form
    /// `Hotkey(string:)` reads. An empty one means the shortcut was turned off.
    var hotkeys: [HotkeyAction: String] = [:]
    var window: Window?

    /// The old window, in the old coordinates: the origin is the top left corner of the main screen.
    struct Window: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    init?(json data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func section(_ name: String, in dict: [String: Any]) -> [String: Any] { dict[name] as? [String: Any] ?? [:] }
        func bool(_ key: String, in dict: [String: Any]) -> Bool? {
            (dict[key] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
        }
        func int(_ key: String, in dict: [String: Any]) -> Int? {
            (dict[key] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue }
        }

        let lastfm = section("lastfm", in: root)
        lastFMSession = lastfm["session"] as? String
        lastFMUser = lastfm["user"] as? String

        lookUpLyrics = bool("use_genius", in: root)
        playbackNotifications = bool("use_terminal_notifier", in: root)

        let playback = section("playback", in: root)
        cursorFollowsPlayback = bool("cursor_follows_playback", in: playback)
        playbackFollowsCursor = bool("playback_follows_cursor", in: playback)

        dontGroupByAlbums = bool("dont_group_by_albums", in: section("playlist", in: root))

        let shortcuts = section("shortcuts", in: root)
        let names: [(String, HotkeyAction)] = [
            ("find_shortcut", .search), ("toggle_shortcut", .playPause), ("next_shortcut", .nextTrack),
            ("previous_shortcut", .previousTrack),
        ]
        for (key, action) in names {
            if let value = shortcuts[key] as? String { hotkeys[action] = value }
        }

        let w = section("window", in: root)
        if let x = int("x", in: w), let y = int("y", in: w), let width = int("width", in: w),
           let height = int("height", in: w) {
            window = Window(x: x, y: y, width: width, height: height)
        }
    }

    /// Puts what is valid into `config`; everything else stays as it is.
    /// `screenHeight`: height of the main screen, to turn the old (top left) window origin into ours (bottom left);
    /// without it the position isn't taken over.
    func apply(to config: inout AppConfig, screenHeight: Int?) {
        if let session = lastFMSession, let user = lastFMUser, !session.isEmpty, !user.isEmpty {
            config.integrations.lastfm = .init(session: session, username: user)
        }
        if let lookUpLyrics { config.integrations.lrclib.enabled = lookUpLyrics }
        if let playbackNotifications { config.general.playbackNotifications = playbackNotifications }
        if let cursorFollowsPlayback { config.playback.cursorFollowsPlayback = cursorFollowsPlayback }
        if let playbackFollowsCursor { config.playback.playbackFollowsCursor = playbackFollowsCursor }

        // A hotkey that is not valid, or that an earlier action has already, is skipped. A shortcut that was turned
        // off stays off, also if the action has a default one now. What an action had by default is taken away if
        // a migrated hotkey of another action is the same.
        var taken = Set<Hotkey>()
        for action in HotkeyAction.allCases {
            guard let text = hotkeys[action] else { continue }
            if text.isEmpty {
                config.hotkeys[action] = ""
                continue
            }
            guard let hotkey = Hotkey(string: text), taken.insert(hotkey).inserted else { continue }
            for other in HotkeyAction.allCases where other != action && Hotkey(string: config.hotkeys[other]) == hotkey {
                config.hotkeys[other] = ""
            }
            config.hotkeys[action] = hotkey.string
        }

        // The size has to be within our limits, otherwise the default window stays; the position then too.
        if let window,
           (ConfigLimits.windowMinWidth...ConfigLimits.windowMaxSide).contains(window.width),
           (ConfigLimits.windowMinHeight...ConfigLimits.windowMaxSide).contains(window.height) {
            config.ui.window.width = window.width
            config.ui.window.height = window.height
            if let screenHeight {
                config.ui.window.x = window.x
                config.ui.window.y = screenHeight - window.y - window.height
            }
        }
    }
}
