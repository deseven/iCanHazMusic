// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// All layout constants in one place. Limits that are also validated in the config
/// come from `ConfigLimits`.
enum Layout {
    // Window (content size, i.e. without the title bar)
    static let windowMinWidth = CGFloat(ConfigLimits.windowMinWidth)
    static let windowMinHeight = CGFloat(ConfigLimits.windowMinHeight)

    // Sidebar (playlist selector)
    static let sidebarMin = CGFloat(ConfigLimits.sidebarMin)
    static let sidebarMax = CGFloat(ConfigLimits.sidebarMax)

    // Playlist column
    static let playlistMinWidth: CGFloat = 280
    static let albumHeaderRowHeight: CGFloat = 68
    /// Album header when the album art is turned off: just the three lines of text.
    static let albumHeaderRowHeightWithoutArt: CGFloat = 52
    static let trackRowHeight: CGFloat = 20
    /// First column of a track row: holds the play symbol of the playing track.
    static let trackStatusColumnWidth: CGFloat = 22
    /// The track number column (fits three digits), right-aligned text so the status symbol can sit right next to it.
    static let trackNumberColumnWidth: CGFloat = 30
    /// What the number column lost against its former width of 44; added to the status column in rows with a number,
    /// so the title keeps its place.
    static let trackNumberSlack: CGFloat = 44 - trackNumberColumnWidth
    /// Column of a track row (right of the title) that holds the lyrics symbol.
    static let trackLyricsColumnWidth: CGFloat = 24
    /// Font size of the track rows.
    static let trackRowFontSize: CGFloat = 12
    /// Column of a track row that holds the duration: as wide as the longest text it may show (`x:xx:xx`).
    static let trackDurationColumnWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: trackRowFontSize, weight: .regular)
        return ceil(("0:00:00" as NSString).size(withAttributes: [.font: font]).width) + 2
    }()
    /// Cover thumbnails are stored at 2x (see `AppConstants.coverThumbnailPixels`).
    static let coverSize = CGFloat(AppConstants.coverThumbnailPixels) / 2
    /// Extra points of rows rendered above/below the visible area of the playlist.
    static let playlistOverscan: CGFloat = 600

    // Playback block (the width includes the padding; the album art fills the rest)
    static let blockMinWidth = CGFloat(ConfigLimits.blockMinWidth)
    static let blockMaxWidth = CGFloat(ConfigLimits.blockMaxWidth)
    static let blockPadding: CGFloat = 16
    static let artToControlsGap: CGFloat = 14
    static let infoToButtonsMinGap: CGFloat = 12
    /// Album art zoom on hover (Preferences > Now Playing) shows the image at its original size; not done if the art
    /// is already shown at this fraction of that size or more (less than 10% smaller).
    static let albumArtNoZoomRatio: CGFloat = 0.9
    /// The default seek bar: the drawn bar and the extra clickable height above and below it.
    static let seekbarBarHeight: CGFloat = 6
    static let seekbarHitMargin: CGFloat = 4
    static let seekbarHeight: CGFloat = seekbarBarHeight + 2 * seekbarHitMargin
    /// The waveform seek bar (the whole frame is drawn and clickable). Fixed, so nothing jumps when the waveform arrives.
    static let waveformSeekbarHeight: CGFloat = 50

    // Preferences window
    static let preferencesWidth: CGFloat = 610
    static let preferencesHeight: CGFloat = 540
    static let preferencesTabsWidth: CGFloat = 170

    // Import progress sheet
    static let importSheetWidth: CGFloat = 380

    // Last.fm connection sheet
    static let lastFMSheetWidth: CGFloat = 380

    // Update sheet
    static let updateSheetWidth: CGFloat = 520
    static let updateChangelogHeight: CGFloat = 180

    // Lyrics sheet
    static let lyricsSheetWidth: CGFloat = 460
    static let lyricsSheetHeight: CGFloat = 580

    // Album art sheet (the art at its original size, shrunk only to fit the window)
    static let artSheetPadding: CGFloat = 20
    /// Room kept free between the sheet and the window's edges.
    static let artSheetWindowMargin: CGFloat = 20
    /// Height reserved for the Close button row and the gap above it.
    static let artSheetButtonRowHeight: CGFloat = 12 + 30
    /// The smallest side the art is shrunk to, however small the window is.
    static let artSheetMinSide: CGFloat = 120

    // Search window
    static let searchWidth: CGFloat = 640
    static let searchFieldHeight: CGFloat = 54
    static let searchRowHeight: CGFloat = 32
    /// The line of key hints at the bottom (under its divider).
    static let searchLegendHeight: CGFloat = 30
    /// Space above and below the result rows.
    static let searchListPadding: CGFloat = 6
    /// Where the window's top edge is, as the share of the screen's height above it.
    static let searchTopOffset: CGFloat = 0.2

    /// Height of the search window with this many rows (a message counts as one), the legend included.
    static func searchHeight(rows: Int) -> CGFloat {
        let legend = 1 + searchLegendHeight
        guard rows > 0 else { return searchFieldHeight + legend }
        return searchFieldHeight + 1 + 2 * searchListPadding + CGFloat(rows) * searchRowHeight + legend
    }

    // Divider between playlist and playback block
    static let dividerLineWidth: CGFloat = 1
    static let dividerHitWidth: CGFloat = 12
}
