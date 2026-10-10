// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Contents of `config.json`.
///
/// Decoding is forgiving: every missing or malformed value falls back to its default,
/// so a partially valid file never discards the rest of the settings.
struct AppConfig: Codable, Equatable {
    struct UI: Codable, Equatable {
        struct Window: Codable, Equatable {
            static let unsetPosition = -1

            var width = 800
            var height = 600
            /// `-1` for both `x` and `y` means "center on the screen".
            var x = Window.unsetPosition
            var y = Window.unsetPosition

            var hasPosition: Bool { !(x == Window.unsetPosition && y == Window.unsetPosition) }

            init() {}

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let d = Window()
                width = c.value(.width, default: d.width)
                height = c.value(.height, default: d.height)
                x = c.value(.x, default: d.x)
                y = c.value(.y, default: d.y)
            }
        }

        struct PlaylistSelector: Codable, Equatable {
            var shown = true
            var width = 140

            init() {}

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let d = PlaylistSelector()
                shown = c.value(.shown, default: d.shown)
                width = c.value(.width, default: d.width)
            }
        }

        var window = Window()
        var playlistSelector = PlaylistSelector()
        var playbackStatusWidth = 270

        enum CodingKeys: String, CodingKey {
            case window
            case playlistSelector = "playlist_selector"
            case playbackStatusWidth = "playback_status_width"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = UI()
            window = c.value(.window, default: d.window)
            playlistSelector = c.value(.playlistSelector, default: d.playlistSelector)
            playbackStatusWidth = c.value(.playbackStatusWidth, default: d.playbackStatusWidth)
        }
    }

    struct General: Codable, Equatable {
        /// System notifications about playback (the track that starts, the end of the playlist). Off: none is sent.
        var playbackNotifications = true
        /// Lyrics are shown (the buttons in the playlist and in the playback block, LRCLIB lookups). Off: embedded
        /// lyrics are still read from the tags, but nothing is shown and nothing is looked up.
        var lyricsSupport = true
        /// Look for a new version on GitHub (at launch and once a day) and offer to install it. A check started
        /// from the About window works regardless.
        var checkForUpdates = true
        /// Version the user chose "Skip this version" for; empty = none. Only automatic checks respect it.
        var skippedUpdate = ""
        /// The playback queue exists: its sidebar item, the menu items, the Space key and the markers in the playlist.
        /// Off: none of that, and nothing can be queued (also not from the search window).
        var queueEnabled = true
        /// Closing the main window quits the app. Off: only the window closes, playback and everything else go on.
        var closeQuits = false

        enum CodingKeys: String, CodingKey {
            case playbackNotifications = "playback_notifications"
            case lyricsSupport = "lyrics_support"
            case checkForUpdates = "check_for_updates"
            case skippedUpdate = "skipped_update"
            case queueEnabled = "queue_enabled"
            case closeQuits = "close_quits"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = General()
            playbackNotifications = c.value(.playbackNotifications, default: d.playbackNotifications)
            lyricsSupport = c.value(.lyricsSupport, default: d.lyricsSupport)
            checkForUpdates = c.value(.checkForUpdates, default: d.checkForUpdates)
            skippedUpdate = c.value(.skippedUpdate, default: d.skippedUpdate)
            queueEnabled = c.value(.queueEnabled, default: d.queueEnabled)
            closeQuits = c.value(.closeQuits, default: d.closeQuits)
        }
    }

    struct Playback: Codable, Equatable {
        /// The selection moves to the track that starts playing.
        var cursorFollowsPlayback = true
        /// The track under the cursor plays next, instead of the one after the current track.
        var playbackFollowsCursor = true
        /// Which track follows the current one.
        var order = PlaybackOrder.default
        /// What happens after the last track of the playlist.
        var atPlaylistEnd = PlaylistEnd.default
        /// Playback stops when the queue has been played through, instead of going on in the playlist.
        var stopAtQueueEnd = false

        enum CodingKeys: String, CodingKey {
            case cursorFollowsPlayback = "cursor_follows_playback"
            case playbackFollowsCursor = "playback_follows_cursor"
            case order
            case atPlaylistEnd = "at_playlist_end"
            case stopAtQueueEnd = "stop_at_queue_end"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Playback()
            cursorFollowsPlayback = c.value(.cursorFollowsPlayback, default: d.cursorFollowsPlayback)
            playbackFollowsCursor = c.value(.playbackFollowsCursor, default: d.playbackFollowsCursor)
            order = c.value(.order, default: d.order)
            atPlaylistEnd = c.value(.atPlaylistEnd, default: d.atPlaylistEnd)
            stopAtQueueEnd = c.value(.stopAtQueueEnd, default: d.stopAtQueueEnd)
        }
    }

    struct PlaybackEngine: Codable, Equatable {
        /// Quality of the sample rate conversion.
        var resampleQuality = ResampleQuality.default
        /// Linear gain, `ConfigLimits.volumeMin...volumeMax`.
        var volume = 0.7

        enum CodingKeys: String, CodingKey {
            case resampleQuality = "resample_quality"
            case volume
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = PlaybackEngine()
            resampleQuality = c.value(.resampleQuality, default: d.resampleQuality)
            volume = c.value(.volume, default: d.volume)
        }
    }

    struct NowPlaying: Codable, Equatable {
        /// How the seek bar of the playback block looks.
        var seekbarStyle = SeekbarStyle.default
        /// Hovering the album art zooms into the part under the pointer.
        var zoomAlbumArt = false

        enum CodingKeys: String, CodingKey {
            case seekbarStyle = "seekbar_style"
            case zoomAlbumArt = "zoom_album_art"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = NowPlaying()
            seekbarStyle = c.value(.seekbarStyle, default: d.seekbarStyle)
            zoomAlbumArt = c.value(.zoomAlbumArt, default: d.zoomAlbumArt)
        }
    }

    struct Playlist: Codable, Equatable {
        /// Files whose tags are read at the same time; `ConfigLimits.tagParsingConcurrencyAuto` (0) = automatic.
        var tagParsingConcurrency = ConfigLimits.tagParsingConcurrencyAuto
        /// Show the album art in the album blocks of grouped playlists (it is cached either way).
        var displayAlbumArt = true

        enum CodingKeys: String, CodingKey {
            case tagParsingConcurrency = "tag_parsing_concurrency"
            case displayAlbumArt = "display_album_art"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Playlist()
            tagParsingConcurrency = c.value(.tagParsingConcurrency, default: d.tagParsingConcurrency)
            displayAlbumArt = c.value(.displayAlbumArt, default: d.displayAlbumArt)
        }
    }

    struct Search: Codable, Equatable {
        /// Playlists are found by their name (and listed in the results). Off: no playlist is ever a result.
        var byPlaylistName = true
        /// Albums are found by their name (and listed in the results). Off: album names aren't searched at all.
        var byAlbumName = true
        /// Words are also found with typos and as letters in order (`pfloyd`). Off: only parts of the text match.
        var fuzzy = true
        /// Return adds the result to the queue and Shift-Return plays it, instead of the other way round.
        var preferAddingToQueue = false

        enum CodingKeys: String, CodingKey {
            case byPlaylistName = "by_playlist_name"
            case byAlbumName = "by_album_name"
            case fuzzy
            case preferAddingToQueue = "prefer_adding_to_queue"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Search()
            byPlaylistName = c.value(.byPlaylistName, default: d.byPlaylistName)
            byAlbumName = c.value(.byAlbumName, default: d.byAlbumName)
            fuzzy = c.value(.fuzzy, default: d.fuzzy)
            preferAddingToQueue = c.value(.preferAddingToQueue, default: d.preferAddingToQueue)
        }
    }

    struct Hotkeys: Codable, Equatable {
        /// The play/pause, next and previous keys of the keyboard (and headsets) control the player.
        var mediaKeys = true
        /// Hotkey of each action in its text form (see `Hotkey`); an action without one is not in here.
        /// An action that has a default one and is missing in the file keeps it; an empty value in the file is none.
        private var bindings: [HotkeyAction: String] = [.search: "⇧⌘W"]

        /// The hotkey of an action in its text form, empty = none.
        subscript(action: HotkeyAction) -> String {
            get { bindings[action] ?? "" }
            set { bindings[action] = newValue.isEmpty ? nil : newValue }
        }

        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init(_ name: String) { stringValue = name }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }

            static let mediaKeys = Key("media_keys")
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            mediaKeys = (try? c.decodeIfPresent(Bool.self, forKey: .mediaKeys)) ?? Hotkeys().mediaKeys
            for action in HotkeyAction.allCases {
                if let value = try? c.decodeIfPresent(String.self, forKey: Key(action.rawValue)) {
                    self[action] = value
                }
            }
            // A default that was never written to this file doesn't take a combination away from an action
            // the user has given it to.
            for (action, defaultValue) in Hotkeys().bindings where (try? c.decodeIfPresent(String.self, forKey: Key(action.rawValue))) == nil {
                let taken = HotkeyAction.allCases.contains { other in
                    other != action && Hotkey(string: self[other]) != nil && Hotkey(string: self[other]) == Hotkey(string: defaultValue)
                }
                if taken { self[action] = "" }
            }
        }

        /// Every action is written, with an empty string for none, so the file shows what can be set.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(mediaKeys, forKey: .mediaKeys)
            for action in HotkeyAction.allCases {
                try c.encode(self[action], forKey: Key(action.rawValue))
            }
        }
    }

    struct Integrations: Codable, Equatable {
        struct LastFM: Codable, Equatable {
            /// Session key from the authorization; empty = not connected. Only the session is kept, never the
            /// (short-lived) token it was made from, and no password is ever involved.
            var session = ""
            /// Name of the account the session belongs to.
            var username = ""

            var isConnected: Bool { !session.isEmpty && !username.isEmpty }

            init() {}

            init(session: String, username: String) {
                self.session = session
                self.username = username
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let d = LastFM()
                session = c.value(.session, default: d.session)
                username = c.value(.username, default: d.username)
            }
        }

        struct LRCLIB: Codable, Equatable {
            /// Look up the lyrics of played tracks on lrclib.net when the file has none embedded.
            var enabled = false

            init() {}

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                enabled = c.value(.enabled, default: LRCLIB().enabled)
            }
        }

        var lastfm = LastFM()
        var lrclib = LRCLIB()

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Integrations()
            lastfm = c.value(.lastfm, default: d.lastfm)
            lrclib = c.value(.lrclib, default: d.lrclib)
        }
    }

    static let defaultPlaylistName = "main"

    var ui = UI()
    var general = General()
    var playback = Playback()
    var playbackEngine = PlaybackEngine()
    var playlist = Playlist()
    var nowPlaying = NowPlaying()
    var search = Search()
    var hotkeys = Hotkeys()
    var integrations = Integrations()
    var activePlaylist = AppConfig.defaultPlaylistName

    enum CodingKeys: String, CodingKey {
        case ui
        case general
        case playback
        case playbackEngine = "playback_engine"
        case playlist
        case nowPlaying = "now_playing"
        case search
        case hotkeys
        case integrations
        case activePlaylist = "active_playlist"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        ui = c.value(.ui, default: d.ui)
        general = c.value(.general, default: d.general)
        playback = c.value(.playback, default: d.playback)
        playbackEngine = c.value(.playbackEngine, default: d.playbackEngine)
        playlist = c.value(.playlist, default: d.playlist)
        nowPlaying = c.value(.nowPlaying, default: d.nowPlaying)
        search = c.value(.search, default: d.search)
        hotkeys = c.value(.hotkeys, default: d.hotkeys)
        integrations = c.value(.integrations, default: d.integrations)
        activePlaylist = c.value(.activePlaylist, default: d.activePlaylist)
    }

    // MARK: - Validation

    /// Returns a copy where every value outside of the UI constraints is reset to its default.
    /// Constraints that depend on the screen setup are checked later, when the window is restored.
    func validated() -> AppConfig {
        var result = self
        let defaults = AppConfig()

        let w = ui.window
        let sizeIsValid = (ConfigLimits.windowMinWidth...ConfigLimits.windowMaxSide).contains(w.width)
            && (ConfigLimits.windowMinHeight...ConfigLimits.windowMaxSide).contains(w.height)
        if !sizeIsValid {
            // Position makes little sense for a size we don't trust, recenter too.
            result.ui.window = defaults.ui.window
        }

        if !(ConfigLimits.sidebarMin...ConfigLimits.sidebarMax).contains(ui.playlistSelector.width) {
            result.ui.playlistSelector.width = defaults.ui.playlistSelector.width
        }

        if !(ConfigLimits.blockMinWidth...ConfigLimits.blockMaxWidth).contains(ui.playbackStatusWidth) {
            result.ui.playbackStatusWidth = defaults.ui.playbackStatusWidth
        }

        if !(ConfigLimits.volumeMin...ConfigLimits.volumeMax).contains(playbackEngine.volume) {
            result.playbackEngine.volume = defaults.playbackEngine.volume
        }

        if !ConfigLimits.tagParsingConcurrencyOptions.contains(playlist.tagParsingConcurrency) {
            result.playlist.tagParsingConcurrency = defaults.playlist.tagParsingConcurrency
        }

        // A hotkey that isn't valid, or that an earlier action has already, is none. The others are written in
        // their canonical form.
        var taken = Set<Hotkey>()
        for action in HotkeyAction.allCases {
            guard !hotkeys[action].isEmpty else { continue }
            if let hotkey = Hotkey(string: hotkeys[action]), taken.insert(hotkey).inserted {
                result.hotkeys[action] = hotkey.string
            } else {
                result.hotkeys[action] = ""
            }
        }

        // A session without a user name (or the other way round) is half of a connection: not connected.
        if !integrations.lastfm.isConnected {
            result.integrations.lastfm = defaults.integrations.lastfm
        }

        if activePlaylist.isEmpty {
            result.activePlaylist = defaults.activePlaylist
        }

        return result
    }
}

private extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `default` when the key is missing or has the wrong type.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
