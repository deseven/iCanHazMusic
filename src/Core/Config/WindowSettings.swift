// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// Settings of the main window. `nil` for `configStore` (tests): defaults, nothing is persisted.
@MainActor
@Observable
final class WindowSettings {
    static let shared = WindowSettings(configStore: .shared)

    /// What closing the window does ("Close Quits", Preferences > General, config `general.close_quits`, off by
    /// default). Off: the window closes and the app keeps running (playback, hotkeys, media keys, the Dock menu); the
    /// window comes back when something needs it. On: closing the last window quits the app.

    var closeQuits: Bool {
        didSet {
            guard closeQuits != oldValue else { return }
            configStore?.update { $0.general.closeQuits = closeQuits }
            Log.info("close quits: \(closeQuits ? "on" : "off")")
        }
    }

    /// The playlist selector is shown (its toolbar button, config `ui.playlist_selector.shown`).
    var showsPlaylistSelector: Bool {
        didSet {
            guard showsPlaylistSelector != oldValue else { return }
            configStore?.update { $0.ui.playlistSelector.shown = showsPlaylistSelector }
            Log.info("playlist selector: \(showsPlaylistSelector ? "shown" : "hidden")")
        }
    }

    /// The playlist selector (and its toolbar button) is on the right of the window and the now playing block (and
    /// its button) on the left, instead of the other way round ("Swap Playlist Selector with Now Playing",
    /// Preferences > UI, config `ui.swap_playlist_selector_with_now_playing`, off by default).
    var swapsSides: Bool {
        didSet {
            guard swapsSides != oldValue else { return }
            configStore?.update { $0.ui.swapPlaylistSelectorWithNowPlaying = swapsSides }
            Log.info("playlist selector swapped with now playing: \(swapsSides ? "on" : "off")")
        }
    }

    @ObservationIgnored private let configStore: ConfigStore?

    init(configStore: ConfigStore? = nil) {
        self.configStore = configStore
        closeQuits = configStore?.config.general.closeQuits ?? AppConfig.General().closeQuits
        showsPlaylistSelector = configStore?.config.ui.playlistSelector.shown ?? AppConfig.UI.PlaylistSelector().shown
        swapsSides = configStore?.config.ui.swapPlaylistSelectorWithNowPlaying
            ?? AppConfig.UI().swapPlaylistSelectorWithNowPlaying
    }
}
