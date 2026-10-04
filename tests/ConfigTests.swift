import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("AppConfig")
    struct AppConfigTests {
        private func decode(_ json: String) throws -> AppConfig {
            try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        }

        @Test("an empty object gives the defaults")
        func emptyObject() throws {
            #expect(try decode("{}") == AppConfig())
        }

        @Test("reads the snake_case keys")
        func readsKeys() throws {
            let config = try decode("""
            {"active_playlist": "rock",
             "ui": {"window": {"width": 1000, "height": 700, "x": 10, "y": 20},
                    "playlist_selector": {"shown": false, "width": 200},
                    "playback_status_width": 400}}
            """)
            #expect(config.activePlaylist == "rock")
            #expect(config.ui.window.width == 1000)
            #expect(config.ui.window.height == 700)
            #expect(config.ui.window.x == 10)
            #expect(config.ui.window.y == 20)
            #expect(config.ui.window.hasPosition)
            #expect(config.ui.playlistSelector.shown == false)
            #expect(config.ui.playlistSelector.width == 200)
            #expect(config.ui.playbackStatusWidth == 400)
        }

        @Test("a malformed value only resets that value")
        func lenientDecoding() throws {
            let config = try decode("""
            {"active_playlist": 5,
             "ui": {"window": {"width": "wide", "height": 700},
                    "playlist_selector": "nope",
                    "playback_status_width": 333}}
            """)
            let defaults = AppConfig()
            #expect(config.activePlaylist == defaults.activePlaylist)
            #expect(config.ui.window.width == defaults.ui.window.width)
            #expect(config.ui.window.height == 700)
            #expect(config.ui.playlistSelector == defaults.ui.playlistSelector)
            #expect(config.ui.playbackStatusWidth == 333)
        }

        @Test("the playback section is read leniently, with both options on by default")
        func playbackSection() throws {
            let defaults = AppConfig().playback
            #expect(defaults.cursorFollowsPlayback && defaults.playbackFollowsCursor)

            let config = try decode("""
            {"playback": {"cursor_follows_playback": false, "playback_follows_cursor": false}}
            """)
            #expect(!config.playback.cursorFollowsPlayback)
            #expect(!config.playback.playbackFollowsCursor)

            let partial = try decode("""
            {"playback": {"cursor_follows_playback": false, "playback_follows_cursor": "yes"}}
            """)
            #expect(!partial.playback.cursorFollowsPlayback)
            #expect(partial.playback.playbackFollowsCursor)
            #expect(try decode(#"{"playback": 5}"#).playback == defaults)
        }

        @Test("playback settings survive a round trip")
        func playbackRoundTrip() throws {
            var config = AppConfig()
            config.playback.cursorFollowsPlayback = false
            let data = try JSONEncoder().encode(config)
            #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)
        }

        @Test("resample quality is high by default, read by name and reset when unknown")
        func resampleQuality() throws {
            #expect(AppConfig().playback.resampleQuality == .high)
            for quality in ResampleQuality.allCases {
                let json = #"{"playback": {"resample_quality": "\#(quality.rawValue)"}}"#
                #expect(try decode(json).playback.resampleQuality == quality)
            }
            #expect(try decode(#"{"playback": {"resample_quality": "ultra"}}"#).playback.resampleQuality == .high)
            #expect(try decode(#"{"playback": {"resample_quality": 3}}"#).playback.resampleQuality == .high)
        }

        @Test("the volume is 0.7 by default, read leniently and reset outside of 0...1")
        func volume() throws {
            #expect(AppConfig().playback.volume == 0.7)
            #expect(try decode(#"{"playback": {"volume": 0.3}}"#).playback.volume == 0.3)
            #expect(try decode(#"{"playback": {"volume": "loud"}}"#).playback.volume == 0.7)

            for volume in [ConfigLimits.volumeMin, 0.5, ConfigLimits.volumeMax] {
                var config = AppConfig()
                config.playback.volume = volume
                #expect(config.validated() == config)
            }
            for volume in [-0.1, 1.5, 70] {
                var config = AppConfig()
                config.playback.volume = volume
                #expect(config.validated().playback.volume == 0.7)
            }
        }

        @Test("the media keys are on and no custom hotkey is set by default")
        func hotkeyDefaults() throws {
            let defaults = AppConfig().hotkeys
            #expect(defaults.mediaKeys)
            #expect(HotkeyAction.allCases.allSatisfy { defaults[$0].isEmpty })
            #expect(try decode("{}").hotkeys == defaults)
        }

        @Test("hotkeys are read by the names of the actions")
        func hotkeyKeys() throws {
            let config = try decode("""
            {"hotkeys": {"media_keys": false, "play_pause": "⌃⌥P", "next_track": "⌃⌥→", "previous_track": "⌃⌥←",
                         "next_album": "⌃⌥⌘→", "previous_album": "⌃⌥⌘←", "random_track": "⌃⌥R",
                         "random_album": "⌃⌥⌘R", "volume_up": "⌃⌥↑", "volume_down": "⌃⌥↓"}}
            """)
            #expect(!config.hotkeys.mediaKeys)
            #expect(config.hotkeys[.playPause] == "⌃⌥P")
            #expect(config.hotkeys[.nextTrack] == "⌃⌥→")
            #expect(config.hotkeys[.previousTrack] == "⌃⌥←")
            #expect(config.hotkeys[.nextAlbum] == "⌃⌥⌘→")
            #expect(config.hotkeys[.previousAlbum] == "⌃⌥⌘←")
            #expect(config.hotkeys[.randomTrack] == "⌃⌥R")
            #expect(config.hotkeys[.randomAlbum] == "⌃⌥⌘R")
            #expect(config.hotkeys[.volumeUp] == "⌃⌥↑")
            #expect(config.hotkeys[.volumeDown] == "⌃⌥↓")
            #expect(config.validated() == config)
        }

        @Test("the hotkeys section is read leniently")
        func hotkeysLenient() throws {
            let config = try decode(#"{"hotkeys": {"media_keys": "no", "play_pause": 5, "next_track": "⌃⌥N"}}"#)
            #expect(config.hotkeys.mediaKeys)
            #expect(config.hotkeys[.playPause].isEmpty)
            #expect(config.hotkeys[.nextTrack] == "⌃⌥N")
            #expect(try decode(#"{"hotkeys": 5}"#).hotkeys == AppConfig().hotkeys)
        }

        @Test("every hotkey is written, empty when not set")
        func hotkeysEncoding() throws {
            var config = AppConfig()
            config.hotkeys[.playPause] = "⌃⌥P"
            let data = try #require(ConfigStore.encode(config))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hotkeys = try #require(object["hotkeys"] as? [String: Any])
            #expect(hotkeys["media_keys"] as? Bool == true)
            #expect(hotkeys["play_pause"] as? String == "⌃⌥P")
            #expect(hotkeys["volume_down"] as? String == "")
            #expect(hotkeys.count == 1 + HotkeyAction.allCases.count)
            #expect(try decode(String(decoding: data, as: UTF8.self)) == config)
        }

        @Test("invalid and repeated hotkeys are reset, the others written canonically")
        func hotkeysValidation() {
            var config = AppConfig()
            config.hotkeys[.playPause] = "G"               // needs a modifier
            config.hotkeys[.nextTrack] = "⌘⌥⌃N"            // not canonical
            config.hotkeys[.previousTrack] = "⌃⌥⌘N"       // the same again
            config.hotkeys[.nextAlbum] = "nonsense"
            config.hotkeys[.volumeUp] = "⌃⌥↑"

            let valid = config.validated().hotkeys
            #expect(valid[.playPause].isEmpty)
            #expect(valid[.nextTrack] == "⌃⌥⌘N")
            #expect(valid[.previousTrack].isEmpty)         // the first action keeps it
            #expect(valid[.nextAlbum].isEmpty)
            #expect(valid[.volumeUp] == "⌃⌥↑")
        }

        @Test("last.fm is not connected by default; the session and user name are read leniently")
        func lastFMSection() throws {
            let defaults = AppConfig().integrations.lastfm
            #expect(!defaults.isConnected && defaults.session.isEmpty && defaults.username.isEmpty)

            let config = try decode("""
            {"integrations": {"lastfm": {"session": "abc", "username": "bob"}}}
            """)
            #expect(config.integrations.lastfm == AppConfig.Integrations.LastFM(session: "abc", username: "bob"))
            #expect(config.integrations.lastfm.isConnected)
            #expect(config.validated() == config)

            #expect(try decode(#"{"integrations": 5}"#).integrations == AppConfig().integrations)
            #expect(try decode(#"{"integrations": {"lastfm": {"session": 7, "username": "bob"}}}"#)
                .validated().integrations.lastfm == defaults)
        }

        @Test("a session without a user name, or the other way round, is no connection")
        func halfConnection() {
            for half in [AppConfig.Integrations.LastFM(session: "abc", username: ""),
                         AppConfig.Integrations.LastFM(session: "", username: "bob")] {
                var config = AppConfig()
                config.integrations.lastfm = half
                #expect(config.validated().integrations.lastfm == AppConfig.Integrations.LastFM())
            }
        }

        @Test("the playlist section is read leniently, with automatic concurrency and art on by default")
        func playlistSection() throws {
            let defaults = AppConfig().playlist
            #expect(defaults.tagParsingConcurrency == ConfigLimits.tagParsingConcurrencyAuto)
            #expect(defaults.displayAlbumArt)

            let config = try decode("""
            {"playlist": {"tag_parsing_concurrency": 8, "display_album_art": false}}
            """)
            #expect(config.playlist.tagParsingConcurrency == 8)
            #expect(!config.playlist.displayAlbumArt)

            let partial = try decode("""
            {"playlist": {"tag_parsing_concurrency": "many", "display_album_art": false}}
            """)
            #expect(partial.playlist.tagParsingConcurrency == defaults.tagParsingConcurrency)
            #expect(!partial.playlist.displayAlbumArt)
            #expect(try decode(#"{"playlist": 5}"#).playlist == defaults)
        }

        @Test("the tag parsing concurrency must be one of the offered values")
        func invalidConcurrency() {
            for count in ConfigLimits.tagParsingConcurrencyOptions {
                var config = AppConfig()
                config.playlist.tagParsingConcurrency = count
                #expect(config.validated() == config)
            }
            for count in [-1, 3, 33, 64] {
                var config = AppConfig()
                config.playlist.tagParsingConcurrency = count
                config.playlist.displayAlbumArt = false
                let result = config.validated()
                #expect(result.playlist.tagParsingConcurrency == ConfigLimits.tagParsingConcurrencyAuto)
                #expect(!result.playlist.displayAlbumArt)
            }
        }

        @Test("the default window has no position")
        func defaultPosition() {
            #expect(!AppConfig().ui.window.hasPosition)
            var window = AppConfig.UI.Window()
            window.x = 0
            #expect(window.hasPosition)
        }

        @Test("round-trips through JSON")
        func roundTrip() throws {
            var config = AppConfig()
            config.activePlaylist = "jazz"
            config.ui.window.width = 1234
            config.ui.playlistSelector.shown = false
            let data = try JSONEncoder().encode(config)
            #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)
        }

        // MARK: validated()

        @Test("valid values are kept")
        func validKept() {
            var config = AppConfig()
            config.ui.window.width = 1200
            config.ui.window.height = 900
            config.ui.window.x = 5
            config.ui.window.y = 5
            config.ui.playlistSelector.width = 180
            config.ui.playbackStatusWidth = 500
            config.activePlaylist = "x"
            #expect(config.validated() == config)
        }

        @Test("limits are inclusive")
        func limitsInclusive() {
            var config = AppConfig()
            config.ui.window.width = ConfigLimits.windowMinWidth
            config.ui.window.height = ConfigLimits.windowMaxSide
            config.ui.playlistSelector.width = ConfigLimits.sidebarMax
            config.ui.playbackStatusWidth = ConfigLimits.blockMinWidth
            #expect(config.validated() == config)
        }

        @Test("a window size outside the limits resets size and position")
        func invalidWindow() {
            for (w, h) in [(ConfigLimits.windowMinWidth - 1, 700), (900, ConfigLimits.windowMinHeight - 1),
                           (ConfigLimits.windowMaxSide + 1, 700)] {
                var config = AppConfig()
                config.ui.window.width = w
                config.ui.window.height = h
                config.ui.window.x = 50
                config.ui.window.y = 60
                #expect(config.validated().ui.window == AppConfig().ui.window)
            }
        }

        @Test("sidebar and playback block widths are reset independently")
        func invalidWidths() {
            var config = AppConfig()
            config.ui.window.width = 1000
            config.ui.playlistSelector.width = ConfigLimits.sidebarMin - 1
            config.ui.playbackStatusWidth = ConfigLimits.blockMaxWidth + 1
            let result = config.validated()
            #expect(result.ui.playlistSelector.width == AppConfig().ui.playlistSelector.width)
            #expect(result.ui.playbackStatusWidth == AppConfig().ui.playbackStatusWidth)
            #expect(result.ui.window.width == 1000)
        }

        @Test("an empty active playlist name is reset")
        func emptyActivePlaylist() {
            var config = AppConfig()
            config.activePlaylist = ""
            #expect(config.validated().activePlaylist == AppConfig.defaultPlaylistName)
        }
    }

    @MainActor @Suite("ConfigStore")
    struct ConfigStoreTests {
        private func makePaths(_ dir: TempDir) -> AppPaths {
            AppPaths(workDir: dir.path("work"))
        }

        private func readConfig(_ paths: AppPaths) throws -> AppConfig {
            try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configURL))
        }

        @Test("writes the defaults when there is no config yet")
        func createsDefaults() throws {
            let dir = try TempDir()
            let paths = makePaths(dir)
            let store = ConfigStore(paths: paths)
            #expect(store.config == AppConfig())
            #expect(try readConfig(paths) == AppConfig())
        }

        @Test("the file is pretty printed with sorted keys and a trailing newline")
        func fileFormat() throws {
            let dir = try TempDir()
            let paths = makePaths(dir)
            _ = ConfigStore(paths: paths)
            let text = try String(contentsOf: paths.configURL, encoding: .utf8)
            #expect(text.hasSuffix("}\n"))
            #expect(text.contains("\n  \"active_playlist\""))
            let activeAt = try #require(text.range(of: "active_playlist"))
            let uiAt = try #require(text.range(of: "\"ui\""))
            #expect(activeAt.lowerBound < uiAt.lowerBound)
        }

        @Test("loads an existing config and fixes invalid values in the file")
        func loadsAndNormalizes() throws {
            let dir = try TempDir()
            let paths = makePaths(dir)
            try dir.write("work/config.json", Data("""
            {"active_playlist": "rock", "ui": {"playback_status_width": 99999,
             "playlist_selector": {"width": 150, "shown": false}}}
            """.utf8))

            let store = ConfigStore(paths: paths)
            #expect(store.config.activePlaylist == "rock")
            #expect(store.config.ui.playlistSelector.width == 150)
            #expect(store.config.ui.playlistSelector.shown == false)
            #expect(store.config.ui.playbackStatusWidth == AppConfig().ui.playbackStatusWidth)

            let onDisk = try readConfig(paths)
            #expect(onDisk == store.config)
        }

        @Test("a broken file results in the defaults being written")
        func brokenFile() throws {
            let dir = try TempDir()
            let paths = makePaths(dir)
            try dir.write("work/config.json", Data("{ this is not json".utf8))

            let store = ConfigStore(paths: paths)
            #expect(store.config == AppConfig())
            #expect(try readConfig(paths) == AppConfig())
        }

        @Test("an unchanged, valid file is not rewritten")
        func validFileUntouched() throws {
            let dir = try TempDir()
            let paths = makePaths(dir)
            _ = ConfigStore(paths: paths)
            let before = try Data(contentsOf: paths.configURL)
            let attributesBefore = try FileManager.default.attributesOfItem(atPath: paths.configURL.path)

            _ = ConfigStore(paths: paths)
            #expect(try Data(contentsOf: paths.configURL) == before)
            let attributesAfter = try FileManager.default.attributesOfItem(atPath: paths.configURL.path)
            #expect(attributesAfter[.modificationDate] as? Date == attributesBefore[.modificationDate] as? Date)
        }

        @Test("update applies the change, flush writes it")
        func updateAndFlush() throws {
            let dir = try TempDir()
            let paths = makePaths(dir)
            let store = ConfigStore(paths: paths, saveDelay: .seconds(60))

            store.update { $0.activePlaylist = "jazz" }
            #expect(store.config.activePlaylist == "jazz")
            #expect(try readConfig(paths).activePlaylist == AppConfig.defaultPlaylistName)   // still pending

            store.flush()
            #expect(try readConfig(paths).activePlaylist == "jazz")

            let reloaded = ConfigStore(paths: paths)
            #expect(reloaded.config.activePlaylist == "jazz")
        }

        @Test("writes happen on their own after the save delay")
        func debouncedWrite() async throws {
            let dir = try TempDir()
            let paths = makePaths(dir)
            let store = ConfigStore(paths: paths, saveDelay: .milliseconds(30))

            store.update { $0.ui.window.width = 1111 }
            store.update { $0.ui.window.width = 1222 }
            let written = await waitUntil { (try? readConfig(paths))?.ui.window.width == 1222 }
            #expect(written)
        }

        @Test("an update that changes nothing schedules no write")
        func noopUpdate() throws {
            let dir = try TempDir()
            let paths = makePaths(dir)
            let store = ConfigStore(paths: paths, saveDelay: .seconds(60))
            try FileManager.default.removeItem(at: paths.configURL)

            store.update { $0.activePlaylist = AppConfig.defaultPlaylistName }
            store.flush()
            #expect(!FileManager.default.fileExists(atPath: paths.configURL.path))
        }

        @Test("flush without pending changes does nothing")
        func flushWithoutChanges() throws {
            let dir = try TempDir()
            let paths = makePaths(dir)
            let store = ConfigStore(paths: paths, saveDelay: .seconds(60))
            try FileManager.default.removeItem(at: paths.configURL)
            store.flush()
            #expect(!FileManager.default.fileExists(atPath: paths.configURL.path))
        }
    }
}
