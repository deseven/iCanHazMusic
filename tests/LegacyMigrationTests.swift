// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("LegacyMigration")
    struct LegacyMigrationTests {
        private static let settings = """
        {
          "shortcuts": {"find_shortcut": "⇧⌘W", "toggle_shortcut": "F17", "next_shortcut": "F18", "previous_shortcut": "F16"},
          "playlist": {"title_width": 315, "dont_group_by_albums": true},
          "last_played_track_id": 5922,
          "playback": {"playback_follows_cursor": true, "stop_at_queue_end": true,
                       "cursor_follows_playback": false, "playback_order": "shuffle_tracks"},
          "use_genius": true,
          "use_terminal_notifier": false,
          "window": {"height": 858, "width": 1695, "x": 156, "y": 37, "fullscreen": false},
          "web": {"use_web_server": true, "web_server_port": 8008, "api_key": "x"},
          "volume": 1,
          "lastfm": {"user": "someone", "session": "abc"}
        }
        """

        private func parse(_ json: String) throws -> LegacySettings {
            try #require(LegacySettings(json: Data(json.utf8)))
        }

        // MARK: - Detection

        @Test("needed only without config.json and with settings.json")
        func detection() throws {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.url)
            #expect(!LegacyMigration.isNeeded(paths: paths))
            try dir.write("current_state.json", Data("[]".utf8))
            #expect(!LegacyMigration.isNeeded(paths: paths))
            try dir.write("settings.json", Data("{}".utf8))
            #expect(LegacyMigration.isNeeded(paths: paths))
            try dir.write("config.json", Data("{}".utf8))
            #expect(!LegacyMigration.isNeeded(paths: paths))
        }

        // MARK: - Settings

        @Test("reads and applies the settings that have a counterpart")
        func appliesSettings() throws {
            let legacy = try parse(Self.settings)
            #expect(legacy.dontGroupByAlbums == true)

            var config = AppConfig()
            legacy.apply(to: &config, screenHeight: 1000)

            #expect(config.integrations.lastfm == .init(session: "abc", username: "someone"))
            #expect(config.integrations.lrclib.enabled)
            #expect(!config.general.playbackNotifications)   // use_terminal_notifier
            #expect(config.playback.cursorFollowsPlayback == false)
            #expect(config.playback.playbackFollowsCursor == true)
            #expect(config.hotkeys[.search] == "⇧⌘W")      // find_shortcut
            #expect(config.hotkeys[.playPause] == "F17")
            #expect(config.hotkeys[.nextTrack] == "F18")
            #expect(config.hotkeys[.previousTrack] == "F16")
            #expect(config.ui.window.width == 1695)
            #expect(config.ui.window.height == 858)
            #expect(config.ui.window.x == 156)
            #expect(config.ui.window.y == 1000 - 37 - 858)   // from the top left to the bottom left origin
            // Ignored ones.
            #expect(config.playbackEngine.volume == AppConfig().playbackEngine.volume)
            #expect(config.hotkeys[.volumeUp].isEmpty)
        }

        @Test("a window outside our limits is left alone; without a screen the position is too")
        func windowConstraints() throws {
            var config = AppConfig()
            try parse(#"{"window": {"x": 1, "y": 2, "width": 300, "height": 200}}"#).apply(to: &config, screenHeight: 1000)
            #expect(config.ui.window == AppConfig().ui.window)

            try parse(#"{"window": {"x": 1, "y": 2, "width": 900, "height": 700}}"#).apply(to: &config, screenHeight: nil)
            #expect(config.ui.window.width == 900)
            #expect(config.ui.window.height == 700)
            #expect(!config.ui.window.hasPosition)
        }

        @Test("invalid and repeated hotkeys are skipped")
        func hotkeys() throws {
            var config = AppConfig()
            try parse(#"{"shortcuts": {"toggle_shortcut": "G", "next_shortcut": "F18", "previous_shortcut": "F18"}}"#)
                .apply(to: &config, screenHeight: nil)
            #expect(config.hotkeys[.playPause].isEmpty)
            #expect(config.hotkeys[.nextTrack] == "F18")
            #expect(config.hotkeys[.previousTrack].isEmpty)
        }

        @Test("find_shortcut becomes the search hotkey; off stays off; a migrated one takes the default's place")
        func searchHotkey() throws {
            var config = AppConfig()
            try parse(#"{"shortcuts": {"find_shortcut": "⌃⌥F"}}"#).apply(to: &config, screenHeight: nil)
            #expect(config.hotkeys[.search] == "⌃⌥F")

            config = AppConfig()
            try parse(#"{"shortcuts": {"find_shortcut": ""}}"#).apply(to: &config, screenHeight: nil)
            #expect(config.hotkeys[.search].isEmpty)

            config = AppConfig()
            try parse(#"{"shortcuts": {"toggle_shortcut": "⇧⌘W"}}"#).apply(to: &config, screenHeight: nil)
            #expect(config.hotkeys[.playPause] == "⇧⌘W")
            #expect(config.hotkeys[.search].isEmpty)
            #expect(config.validated() == config)
        }

        @Test("a half Last.fm login and missing values change nothing")
        func partialSettings() throws {
            var config = AppConfig()
            try parse(#"{"lastfm": {"user": "someone", "session": ""}}"#).apply(to: &config, screenHeight: 1000)
            #expect(config == AppConfig())
            try parse("{}").apply(to: &config, screenHeight: 1000)
            #expect(config == AppConfig())
        }

        @Test("garbage isn't settings")
        func garbage() {
            #expect(LegacySettings(json: Data("nope".utf8)) == nil)
            #expect(LegacySettings(json: Data("[]".utf8)) == nil)
        }

        // MARK: - State

        @Test("the playlist is read in order, duplicates kept, headers and unusable rows dropped")
        func state() {
            let json = """
            [{"file": "/m/a/01.mp3", "title": "A"},
             {"isAlbum": "1", "file": "/m/a/"},
             {"file": "/m/b/02.flac"},
             {"file": "/m/a/01.mp3"},
             {"file": ""},
             {"file": "/m/notes.txt"},
             {"title": "no file"}]
            """
            #expect(LegacyMigration.parseState(Data(json.utf8)).map(\.path) == ["/m/a/01.mp3", "/m/b/02.flac", "/m/a/01.mp3"])
            #expect(LegacyMigration.parseState(Data("nope".utf8)).isEmpty)
        }

        @Test("loadPlan reads both files from the directory")
        func loadPlan() throws {
            let dir = try TempDir()
            try dir.write("settings.json", Data(Self.settings.utf8))
            try dir.write("current_state.json", Data(#"[{"file": "/m/a.mp3"}]"#.utf8))
            let plan = LegacyMigration.loadPlan(paths: AppPaths(workDir: dir.url))
            #expect(plan.settings?.lastFMUser == "someone")
            #expect(plan.files.map(\.path) == ["/m/a.mp3"])

            let empty = LegacyMigration.loadPlan(paths: AppPaths(workDir: try TempDir().url))
            #expect(empty.settings == nil)
            #expect(empty.files.isEmpty)
        }

        // MARK: - Clean up

        @Test("clean up keeps only config.json, app.log, .cache and playlists")
        func cleanUp() throws {
            let dir = try TempDir()
            try dir.write("config.json")
            try dir.write("app.log")
            try dir.write("playlists/main.json")
            try dir.write(".cache/covers.sqlite")
            try dir.write("settings.json")
            try dir.write("current_state.json")
            try dir.write("current_state.json.backup")
            try dir.write("lyrics/a.txt")
            try dir.write("tmp/b.jpg")
            try dir.write("web/index.html")

            LegacyMigration.cleanUp(paths: AppPaths(workDir: dir.url))

            let left = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted()
            #expect(left == [".cache", "app.log", "config.json", "playlists"])
            #expect(FileManager.default.fileExists(atPath: dir.path("playlists/main.json").path))
            #expect(FileManager.default.fileExists(atPath: dir.path(".cache/covers.sqlite").path))
        }
    }
}
