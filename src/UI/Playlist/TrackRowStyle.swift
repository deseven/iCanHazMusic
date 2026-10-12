// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// How the rows of a playlist look (`PlaylistSettings` as a plain value, so the list re-renders when it changes): the
/// columns of the track rows in each mode, the style of the album blocks, and the size of the track rows.
/// Everything in a track row (text, symbols, column widths, gaps, the row's height) is its usual size times `scale`;
/// album blocks don't scale.
struct TrackRowStyle: Equatable {
    let scale: CGFloat
    /// The columns shown, in order.
    let albumColumns: [PlaylistColumn]
    let flatColumns: [PlaylistColumn]
    let headerStyle: AlbumHeaderStyle
    /// Whole points, so row offsets don't drift.
    let rowHeight: CGFloat
    let fontSize: CGFloat
    /// As wide as the longest text it may show (`x:xx:xx`) at `fontSize`.
    let durationWidth: CGFloat

    static let standard = TrackRowStyle()

    init(scale: Int = ConfigLimits.playlistEntriesScaleDefault,
         albumColumns: [PlaylistColumn] = PlaylistColumnsLayout.default(.album).visible,
         flatColumns: [PlaylistColumn] = PlaylistColumnsLayout.default(.flat).visible,
         headerStyle: AlbumHeaderStyle = .default) {
        let scale = CGFloat(scale) / 100
        self.scale = scale
        self.albumColumns = albumColumns
        self.flatColumns = flatColumns
        self.headerStyle = headerStyle
        rowHeight = (Layout.trackRowHeight * scale).rounded()
        fontSize = Layout.trackRowFontSize * scale
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        durationWidth = ceil(("0:00:00" as NSString).size(withAttributes: [.font: font]).width) + 2
    }

    @MainActor
    init(_ settings: PlaylistSettings) {
        self.init(scale: settings.entriesScale, albumColumns: settings.albumColumns.visible,
                  flatColumns: settings.flatColumns.visible, headerStyle: settings.albumHeaderStyle)
    }

    /// The album blocks show the album art (and only then is it loaded).
    var showsAlbumArt: Bool { headerStyle.showsArt }

    func columns(isFlat: Bool) -> [PlaylistColumn] {
        isFlat ? flatColumns : albumColumns
    }

    /// A size of the track rows (`Layout.track...`) at this scale.
    func scaled(_ size: CGFloat) -> CGFloat {
        size * scale
    }
}
