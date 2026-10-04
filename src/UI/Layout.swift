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
    /// Column of a track row (right of the title) that holds the lyrics symbol.
    static let trackLyricsColumnWidth: CGFloat = 24
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

    // Preferences window
    static let preferencesWidth: CGFloat = 610
    static let preferencesHeight: CGFloat = 540
    static let preferencesTabsWidth: CGFloat = 170

    // Import progress sheet
    static let importSheetWidth: CGFloat = 380

    // Last.fm connection sheet
    static let lastFMSheetWidth: CGFloat = 380

    // Lyrics sheet
    static let lyricsSheetWidth: CGFloat = 460
    static let lyricsSheetHeight: CGFloat = 580

    // Divider between playlist and playback block
    static let dividerLineWidth: CGFloat = 1
    static let dividerHitWidth: CGFloat = 12
}
