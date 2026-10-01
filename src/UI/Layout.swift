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
    static let trackRowHeight: CGFloat = 20
    static let coverSize: CGFloat = 56
    /// Extra points of rows rendered above/below the visible area of the playlist.
    static let playlistOverscan: CGFloat = 600

    // Playback block (the width includes the padding; the album art fills the rest)
    static let blockMinWidth = CGFloat(ConfigLimits.blockMinWidth)
    static let blockMaxWidth = CGFloat(ConfigLimits.blockMaxWidth)
    static let blockPadding: CGFloat = 16
    static let artToControlsGap: CGFloat = 14
    static let infoToButtonsMinGap: CGFloat = 12

    // Import progress sheet
    static let importSheetWidth: CGFloat = 380

    // Divider between playlist and playback block
    static let dividerLineWidth: CGFloat = 1
    static let dividerHitWidth: CGFloat = 12
}
