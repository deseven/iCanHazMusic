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

    /// `showAlbumArt`: see `headerHeight`.
    init(playlist: Playlist, showAlbumArt: Bool) {
        let headerHeight = Self.headerHeight(showAlbumArt: showAlbumArt)
        self.init(heights: playlist.rows.map { $0.isHeader ? headerHeight : Layout.trackRowHeight })
    }

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

    /// Rows intersecting `[minY, maxY]`, extended by `overscan` points on both sides.
    func rowRange(minY: CGFloat, maxY: CGFloat, overscan: CGFloat) -> Range<Int> {
        guard rowCount > 0 else { return 0..<0 }
        let first = rowIndex(atOffset: max(0, minY - overscan))
        let last = rowIndex(atOffset: min(totalHeight - 1, max(0, maxY + overscan)))
        return first..<(last + 1)
    }
}
