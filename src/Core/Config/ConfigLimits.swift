// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Limits for values stored in `config.json`. Values outside of them are reset to defaults.
/// The UI derives its sizing constants from these (see `Layout`), so both always agree.
enum ConfigLimits {
    // Window (content size, i.e. without the title bar)
    static let windowMinWidth = 800
    static let windowMinHeight = 600
    static let windowMaxSide = 20_000

    // Playlist selector
    static let playlistSelectorMinWidth = 120
    static let playlistSelectorMaxWidth = 250

    // Now playing block
    static let nowPlayingMinWidth = 270
    static let nowPlayingMaxWidth = 1200

    // Playback volume (linear gain)
    static let volumeMin = 0.0
    static let volumeMax = 1.0

    // Text templates of the now playing components (Title, Subtitle), in characters.
    static let componentTextMaxLength = 200

    // Font size of the Title and the Subtitle, in percent of the usual size.
    static let componentTextScaleMin = 70
    static let componentTextScaleMax = 200
    static let componentTextScaleDefault = 100

    // Size of the track rows of playlists (and of the queue): text and columns, in percent of the usual size.
    static let playlistEntriesScaleMin = 70
    static let playlistEntriesScaleMax = 200
    static let playlistEntriesScaleDefault = 100

    // Read-ahead buffer of the playback engine, in seconds.
    static let readAheadDefault = 5
    static let readAheadOptions = [2, readAheadDefault, 15, 30, 60]

    // Tag parsing: files read at the same time. 0 = automatic (see `TagReader.defaultConcurrency`).
    static let tagParsingConcurrencyAuto = 0
    static let tagParsingConcurrencyOptions = [tagParsingConcurrencyAuto, 1, 2, 4, 8, 16, 32]
}
