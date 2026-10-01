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

    static let defaultPlaylistName = "main"

    var ui = UI()
    var activePlaylist = AppConfig.defaultPlaylistName

    enum CodingKeys: String, CodingKey {
        case ui
        case activePlaylist = "active_playlist"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        ui = c.value(.ui, default: d.ui)
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
