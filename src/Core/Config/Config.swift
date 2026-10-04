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

    struct Playback: Codable, Equatable {
        /// The selection moves to the track that starts playing.
        var cursorFollowsPlayback = true
        /// The track under the cursor plays next, instead of the one after the current track.
        var playbackFollowsCursor = true
        /// Quality of the sample rate conversion.
        var resampleQuality = ResampleQuality.default
        /// Linear gain, `ConfigLimits.volumeMin...volumeMax`.
        var volume = 0.7

        enum CodingKeys: String, CodingKey {
            case cursorFollowsPlayback = "cursor_follows_playback"
            case playbackFollowsCursor = "playback_follows_cursor"
            case resampleQuality = "resample_quality"
            case volume
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Playback()
            cursorFollowsPlayback = c.value(.cursorFollowsPlayback, default: d.cursorFollowsPlayback)
            playbackFollowsCursor = c.value(.playbackFollowsCursor, default: d.playbackFollowsCursor)
            resampleQuality = c.value(.resampleQuality, default: d.resampleQuality)
            volume = c.value(.volume, default: d.volume)
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

    struct Hotkeys: Codable, Equatable {
        /// The play/pause, next and previous keys of the keyboard (and headsets) control the player.
        var mediaKeys = true
        /// Hotkey of each action in its text form (see `Hotkey`); an action without one is not in here.
        private var bindings: [HotkeyAction: String] = [:]

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

        var lastfm = LastFM()

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastfm = c.value(.lastfm, default: Integrations().lastfm)
        }
    }

    static let defaultPlaylistName = "main"

    var ui = UI()
    var playback = Playback()
    var playlist = Playlist()
    var hotkeys = Hotkeys()
    var integrations = Integrations()
    var activePlaylist = AppConfig.defaultPlaylistName

    enum CodingKeys: String, CodingKey {
        case ui
        case playback
        case playlist
        case hotkeys
        case integrations
        case activePlaylist = "active_playlist"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        ui = c.value(.ui, default: d.ui)
        playback = c.value(.playback, default: d.playback)
        playlist = c.value(.playlist, default: d.playlist)
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

        if !(ConfigLimits.volumeMin...ConfigLimits.volumeMax).contains(playback.volume) {
            result.playback.volume = defaults.playback.volume
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
