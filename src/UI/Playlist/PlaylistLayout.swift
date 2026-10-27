// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Vertical geometry of a `Playlist`. Row heights are fixed per kind, so the exact document
/// height is known up front and nothing has to be estimated while scrolling.
struct PlaylistLayout {
    /// Y offset of the top of each row; has `rowCount + 1` entries (last = total height).
    let rowOffsets: [CGFloat]
    let rowCount: Int

    var totalHeight: CGFloat { rowOffsets[rowCount] }

    /// Album headers are as tall as the cover needs (or as the text needs, without it).
    static func headerHeight(showAlbumArt: Bool) -> CGFloat {
        showAlbumArt ? Layout.albumHeaderRowHeight : Layout.albumHeaderRowHeightWithoutArt
    }

    /// `showAlbumArt`: see `headerHeight`; `trackHeight`: the height of a track row (`TrackRowStyle.rowHeight`).
    init(playlist: Playlist, showAlbumArt: Bool, trackHeight: CGFloat = Layout.trackRowHeight) {
        let headerHeight = Self.headerHeight(showAlbumArt: showAlbumArt)
        self.init(heights: playlist.rows.map { $0.isHeader ? headerHeight : trackHeight })
    }

    /// The same as `init(playlist:showAlbumArt:trackHeight:)`, but the last one made is kept and given again for the
    /// same playlist and heights: the playlist view is made anew on every change of the selection (every arrow key),
    /// and a layout has an entry per row.
    @MainActor
    static func cached(for playlist: Playlist, showAlbumArt: Bool, trackHeight: CGFloat) -> PlaylistLayout {
        if let last = lastMade, last.playlist === playlist, last.showAlbumArt == showAlbumArt,
           last.trackHeight == trackHeight {
            return last.layout
        }
        let layout = PlaylistLayout(playlist: playlist, showAlbumArt: showAlbumArt, trackHeight: trackHeight)
        lastMade = (playlist, showAlbumArt, trackHeight, layout)
        return layout
    }

    @MainActor
    private static var lastMade: (playlist: Playlist, showAlbumArt: Bool, trackHeight: CGFloat, layout: PlaylistLayout)?

    /// Rows of the given heights, top to bottom.
    init(heights: [CGFloat]) {
        rowCount = heights.count
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(rowCount + 1)
        var y: CGFloat = 0
        for height in heights {
            offsets.append(y)
            y += height
        }
        offsets.append(y)
        rowOffsets = offsets
    }

    /// Index of the row containing vertical offset `y` (clamped).
    func rowIndex(atOffset y: CGFloat) -> Int {
        var lo = 0, hi = rowCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowOffsets[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The row at vertical offset `y`, nil if there is none (above the first row, below the last one).
    func row(containing y: CGFloat) -> Int? {
        guard rowCount > 0, y >= 0, y < totalHeight else { return nil }
        return rowIndex(atOffset: y)
    }

    /// Rows intersecting `[minY, maxY]`, extended by `overscan` points on both sides.
    func rowRange(minY: CGFloat, maxY: CGFloat, overscan: CGFloat) -> Range<Int> {
        guard rowCount > 0 else { return 0..<0 }
        let first = rowIndex(atOffset: max(0, minY - overscan))
        let last = rowIndex(atOffset: min(totalHeight - 1, max(0, maxY + overscan)))
        return first..<(last + 1)
    }

    /// The rows to render for the visible span `[minY, maxY]` when `current` are the ones rendered now:
    /// - `current` itself while it has every row within `margin` of the span and nothing beyond `2 × overscan`, so the
    ///   rendered rows change in steps rather than with every row scrolled past;
    /// - else the rows of the span plus `overscan` on both sides, or just plus `margin` after a jump (none of
    ///   `current` is needed any more, e.g. the scroll bar is dragged: the next frame is likely to jump again).
    func window(minY: CGFloat, maxY: CGFloat, current: Range<Int>, margin: CGFloat, overscan: CGFloat) -> Range<Int> {
        let needed = rowRange(minY: minY, maxY: maxY, overscan: margin)
        let allowed = rowRange(minY: minY, maxY: maxY, overscan: 2 * overscan)
        if current.lowerBound <= needed.lowerBound, current.upperBound >= needed.upperBound,
           current.lowerBound >= allowed.lowerBound, current.upperBound <= allowed.upperBound {
            return current
        }
        return rowRange(minY: minY, maxY: maxY, overscan: current.overlaps(needed) ? overscan : margin)
    }
}
