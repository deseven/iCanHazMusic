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

        /// The now playing block next to the playlist (what it shows is in `AppConfig.NowPlaying`).
        struct NowPlaying: Codable, Equatable {
            /// Off: the block is gone, and nothing that only it needs is done (no album art loaded, no waveform made).
            var shown = true
            var width = 270

            init() {}

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let d = NowPlaying()
                shown = c.value(.shown, default: d.shown)
                width = c.value(.width, default: d.width)
            }
        }

        var window = Window()
        var playlistSelector = PlaylistSelector()
        var nowPlaying = NowPlaying()
        /// The playlist selector (and its toolbar button) is on the right, the now playing block on the left.
        var swapPlaylistSelectorWithNowPlaying = false

        enum CodingKeys: String, CodingKey {
            case window
            case playlistSelector = "playlist_selector"
            case nowPlaying = "now_playing"
            case swapPlaylistSelectorWithNowPlaying = "swap_playlist_selector_with_now_playing"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = UI()
            window = c.value(.window, default: d.window)
            playlistSelector = c.value(.playlistSelector, default: d.playlistSelector)
            nowPlaying = c.value(.nowPlaying, default: d.nowPlaying)
            swapPlaylistSelectorWithNowPlaying = c.value(.swapPlaylistSelectorWithNowPlaying,
                                                         default: d.swapPlaylistSelectorWithNowPlaying)
        }
    }

    struct General: Codable, Equatable {
        /// System notifications about playback (the track that starts, the end of the playlist). Off: none is sent.
        var playbackNotifications = true
        /// Lyrics are shown (the buttons in the playlist and in the now playing block, LRCLIB lookups). Off: embedded
        /// lyrics are still read from the tags, but nothing is shown and nothing is looked up.
        var lyricsSupport = true
        /// Look for a new version on GitHub (at launch and once a day) and offer to install it. A check started
        /// from the About window works regardless.
        var checkForUpdates = true
        /// Version the user chose "Skip this version" for; empty = none. Only automatic checks respect it.
        var skippedUpdate = ""
        /// The playback queue exists: its item in the playlist selector, the menu items, the Space key and the markers in the playlist.
        /// Off: none of that, and nothing can be queued (also not from the search window).
        var queueEnabled = true
        /// Closing the main window quits the app. Off: only the window closes, playback and everything else go on.
        var closeQuits = false
        /// What plays is picked up at the next launch: the track, the position in it, playing or paused (kept in
        /// `Playback.state`). Off: nothing of it is kept, the app starts silent.
        var restorePlaybackState = true

        enum CodingKeys: String, CodingKey {
            case playbackNotifications = "playback_notifications"
            case lyricsSupport = "lyrics_support"
            case checkForUpdates = "check_for_updates"
            case skippedUpdate = "skipped_update"
            case queueEnabled = "queue_enabled"
            case closeQuits = "close_quits"
            case restorePlaybackState = "restore_playback_state"
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
            restorePlaybackState = c.value(.restorePlaybackState, default: d.restorePlaybackState)
        }
    }

    struct Playback: Codable, Equatable {
        /// Where playback stood, for `General.restorePlaybackState`: the track that plays (or is paused) and the
        /// position in it. Written while something plays and cleared when playback stops; the one exception is the
        /// app quitting, which leaves it for the next launch.
        struct SavedState: Codable, Equatable {
            /// Name of the playlist playback ran from (not necessarily the active one).
            var playlist: String
            var trackID: TrackID
            /// Seconds into the track (into its part for a CUE track).
            var position: Double
            var paused: Bool

            enum CodingKeys: String, CodingKey {
                case playlist
                case trackID = "track_id"
                case position
                case paused
            }

            init(playlist: String, trackID: TrackID, position: Double, paused: Bool) {
                self.playlist = playlist
                self.trackID = trackID
                self.position = position
                self.paused = paused
            }

            /// Names a playlist and a track, at a place that exists.
            var isValid: Bool {
                !playlist.isEmpty && trackID > 0 && position.isFinite && position >= 0
            }
        }

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
        /// Nothing plays: `nil`.
        var state: SavedState?

        enum CodingKeys: String, CodingKey {
            case cursorFollowsPlayback = "cursor_follows_playback"
            case playbackFollowsCursor = "playback_follows_cursor"
            case order
            case atPlaylistEnd = "at_playlist_end"
            case stopAtQueueEnd = "stop_at_queue_end"
            case state
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
            state = try? c.decodeIfPresent(SavedState.self, forKey: .state)
        }
    }

    struct Engine: Codable, Equatable {
        /// Quality of the sample rate conversion.
        var resampleQuality = ResampleQuality.default
        /// Seconds of audio the engine keeps decoded ahead of the playhead; one of `ConfigLimits.readAheadOptions`.
        var readAhead = ConfigLimits.readAheadDefault
        /// UID of the output device; empty = follow the system's default output.
        var outputDevice = ""
        /// Files whose tags are read at the same time; `ConfigLimits.tagParsingConcurrencyAuto` (0) = automatic.
        var tagParsingConcurrency = ConfigLimits.tagParsingConcurrencyAuto
        /// Linear gain, `ConfigLimits.volumeMin...volumeMax`.
        var volume = 0.7

        enum CodingKeys: String, CodingKey {
            case resampleQuality = "resample_quality"
            case readAhead = "read_ahead"
            case outputDevice = "output_device"
            case tagParsingConcurrency = "tag_parsing_concurrency"
            case volume
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Engine()
            resampleQuality = c.value(.resampleQuality, default: d.resampleQuality)
            readAhead = c.value(.readAhead, default: d.readAhead)
            outputDevice = c.value(.outputDevice, default: d.outputDevice)
            tagParsingConcurrency = c.value(.tagParsingConcurrency, default: d.tagParsingConcurrency)
            volume = c.value(.volume, default: d.volume)
        }
    }

    struct NowPlaying: Codable, Equatable {
        /// What the options of the components (the gear in Preferences > Now Playing) are set to.
        struct ComponentOptions: Codable, Equatable {
            static let defaultTitle = "{artist} – {title}"
            static let defaultSubtitle = "{album} ({year})"

            /// How the seek bar looks.
            var seekbarStyle = SeekbarStyle.default
            /// What the Title shows (`TextTemplate`).
            var title = ComponentOptions.defaultTitle
            /// What the Subtitle shows (`TextTemplate`).
            var subtitle = ComponentOptions.defaultSubtitle
            /// Font size of the Title, in percent of the usual size.
            var titleScale = ConfigLimits.componentTextScaleDefault
            /// Font size of the Subtitle, in percent of the usual size.
            var subtitleScale = ConfigLimits.componentTextScaleDefault
            /// Which buttons the Playback Controls have, and where.
            var controls = PlaybackControlsLayout.default

            enum CodingKeys: String, CodingKey {
                case seekbarStyle = "seekbar_style"
                case title
                case subtitle
                case titleScale = "title_scale"
                case subtitleScale = "subtitle_scale"
                case controls
            }

            init() {}

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let d = ComponentOptions()
                seekbarStyle = c.value(.seekbarStyle, default: d.seekbarStyle)
                title = c.value(.title, default: d.title)
                subtitle = c.value(.subtitle, default: d.subtitle)
                titleScale = c.value(.titleScale, default: d.titleScale)
                subtitleScale = c.value(.subtitleScale, default: d.subtitleScale)
                controls = c.value(.controls, default: d.controls)
            }
        }

        /// Which components the block has and where (`top` and `bottom` in the file).
        var layout = NowPlayingLayout.default
        var componentOptions = ComponentOptions()

        enum CodingKeys: String, CodingKey {
            case top
            case bottom
            case componentOptions = "component_options"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = NowPlaying()
            layout = NowPlayingLayout(top: c.items(.top), bottom: c.items(.bottom))
            componentOptions = c.value(.componentOptions, default: d.componentOptions)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)

            try c.encode(layout.top, forKey: .top)
            try c.encode(layout.bottom, forKey: .bottom)
            try c.encode(componentOptions, forKey: .componentOptions)
        }
    }

    struct Playlist: Codable, Equatable {
        /// How the album blocks of grouped playlists look, with or without the album art (it is cached either way).
        var albumHeaderStyle = AlbumHeaderStyle.default
        /// Size of the track rows (text and columns), in percent of the usual size.
        var entriesScale = ConfigLimits.playlistEntriesScaleDefault
        /// The columns of the track rows of playlists grouped by albums.
        var albumColumns = PlaylistColumnsLayout.default(.album)
        /// The columns of the track rows of flat playlists.
        var flatColumns = PlaylistColumnsLayout.default(.flat)

        enum CodingKeys: String, CodingKey {
            case albumHeaderStyle = "album_header_style"
            case entriesScale = "entries_scale"
            case albumColumns = "album_columns"
            case flatColumns = "flat_columns"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Playlist()
            albumHeaderStyle = c.value(.albumHeaderStyle, default: d.albumHeaderStyle)
            entriesScale = c.value(.entriesScale, default: d.entriesScale)
            albumColumns = c.columns(.albumColumns, mode: .album)
            flatColumns = c.columns(.flatColumns, mode: .flat)
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
    var engine = Engine()
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
        case engine
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
        engine = c.value(.engine, default: d.engine)
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

        if !(ConfigLimits.playlistSelectorMinWidth...ConfigLimits.playlistSelectorMaxWidth).contains(ui.playlistSelector.width) {
            result.ui.playlistSelector.width = defaults.ui.playlistSelector.width
        }

        if !(ConfigLimits.nowPlayingMinWidth...ConfigLimits.nowPlayingMaxWidth).contains(ui.nowPlaying.width) {
            result.ui.nowPlaying.width = defaults.ui.nowPlaying.width
        }

        if !(ConfigLimits.volumeMin...ConfigLimits.volumeMax).contains(engine.volume) {
            result.engine.volume = defaults.engine.volume
        }

        if !ConfigLimits.readAheadOptions.contains(engine.readAhead) {
            result.engine.readAhead = defaults.engine.readAhead
        }

        if !ConfigLimits.tagParsingConcurrencyOptions.contains(engine.tagParsingConcurrency) {
            result.engine.tagParsingConcurrency = defaults.engine.tagParsingConcurrency
        }

        if nowPlaying.componentOptions.title.count > ConfigLimits.componentTextMaxLength {
            result.nowPlaying.componentOptions.title = defaults.nowPlaying.componentOptions.title
        }
        if nowPlaying.componentOptions.subtitle.count > ConfigLimits.componentTextMaxLength {
            result.nowPlaying.componentOptions.subtitle = defaults.nowPlaying.componentOptions.subtitle
        }
        let scaleRange = ConfigLimits.componentTextScaleMin...ConfigLimits.componentTextScaleMax
        if !scaleRange.contains(nowPlaying.componentOptions.titleScale) {
            result.nowPlaying.componentOptions.titleScale = defaults.nowPlaying.componentOptions.titleScale
        }
        if !scaleRange.contains(nowPlaying.componentOptions.subtitleScale) {
            result.nowPlaying.componentOptions.subtitleScale = defaults.nowPlaying.componentOptions.subtitleScale
        }
        if !(ConfigLimits.playlistEntriesScaleMin...ConfigLimits.playlistEntriesScaleMax).contains(playlist.entriesScale) {
            result.playlist.entriesScale = defaults.playlist.entriesScale
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

        if let state = playback.state, !state.isValid {
            result.playback.state = defaults.playback.state
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

    /// The now playing components of a list; the ones that can't be read are left out (`NowPlayingLayout` puts back
    /// what is missing).
    func items(_ key: Key) -> [NowPlayingItem] {
        let entries = (try? decodeIfPresent([LossyItem].self, forKey: key)) ?? []
        return entries.compactMap(\.item)
    }

    /// The playlist columns of `mode`; the entries that can't be read are left out (`PlaylistColumnsLayout` puts back
    /// what is missing).
    func columns(_ key: Key, mode: PlaylistMode) -> PlaylistColumnsLayout {
        let entries = (try? decodeIfPresent([Lossy<PlaylistColumnItem>].self, forKey: key)) ?? []
        return PlaylistColumnsLayout(mode: mode, items: entries.compactMap(\.value))
    }
}

private struct LossyItem: Decodable {
    let item: NowPlayingItem?

    init(from decoder: Decoder) throws {
        item = try? NowPlayingItem(from: decoder)
    }
}
