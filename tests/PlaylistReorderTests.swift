// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("PlaylistReorder")
    struct PlaylistReorderTests {
        /// Five tracks of 20 points, the first one at offset 100: slots at 100, 120, ... 180. Dragging row 12 (the third).
        private func tracks(from: Int = 12, grab: CGFloat = 5) -> ReorderDrag {
            ReorderDrag(kind: .track, from: from, range: 10..<15, itemHeight: 20, top: 100, grab: grab,
                        movedID: 1, collapsed: nil, target: from)
        }

        @Test("the dragged item follows the pointer but stays inside its range")
        func drawn() {
            let d = tracks()
            #expect(d.drawnY(pointerY: 145) == 140)         // pointer - grab
            #expect(d.drawnY(pointerY: 0) == 100)           // above the first slot
            #expect(d.drawnY(pointerY: 9999) == 180)        // below the last
            #expect(d.slotY(12) == 140)
        }

        @Test("the target is the nearest slot")
        func target() {
            let d = tracks()
            #expect(d.target(forDrawnY: 140) == 12)
            #expect(d.target(forDrawnY: 149) == 12)
            #expect(d.target(forDrawnY: 151) == 13)
            #expect(d.target(forDrawnY: 100) == 10)
            #expect(d.target(forDrawnY: -500) == 10)
            #expect(d.target(forDrawnY: 5000) == 14)
        }

        @Test("items between the old and the new place make room, in both directions")
        func shifts() {
            var d = tracks()
            d.target = 14
            #expect((10...14).map { d.shift(of: $0) } == [0, 0, 0, -20, -20])
            d.target = 10
            #expect((10...14).map { d.shift(of: $0) } == [20, 20, 0, 0, 0])
            d.target = 12
            #expect((10...14).map { d.shift(of: $0) } == [0, 0, 0, 0, 0])
            d.target = 13
            #expect(d.shift(of: 20) == 0)                    // outside the range
        }

        @Test("an album's slots are as tall as a header, from the top of the list")
        func albums() {
            let d = ReorderDrag(kind: .album, from: 3, range: 0..<10, itemHeight: 68, top: 0, grab: 30, movedID: 1,
                                collapsed: PlaylistLayout(heights: Array(repeating: 68, count: 10)), target: 3)
            #expect(d.slotY(3) == 204)
            #expect(d.drawnY(pointerY: 2000) == 612)
            #expect(d.target(forDrawnY: 612) == 9)
            #expect(d.target(forDrawnY: 204 - 40) == 2)      // 164 is 2.4 slots from the top
            #expect(d.target(forDrawnY: 204 - 36) == 2)      // 168 is 2.47
            #expect(d.target(forDrawnY: 204 - 30) == 3)      // 174 is 2.56 -> still nearest 3
            #expect(d.collapsed?.totalHeight == 680)
        }

        @Test("a layout made of heights")
        func heights() {
            let layout = PlaylistLayout(heights: [68, 20, 20, 68])
            #expect(layout.rowOffsets == [0, 68, 88, 108, 176])
            #expect(layout.rowIndex(atOffset: 90) == 2)

            let p = Make.playlist(Make.entries(dir: "A", album: "A", count: 2))
            #expect(PlaylistLayout(playlist: p, showAlbumArt: true).rowOffsets
                    == [0, Layout.albumHeaderRowHeight, Layout.albumHeaderRowHeight + 20, Layout.albumHeaderRowHeight + 40])
        }

        @Test("the cached layout is the one for the playlist and heights asked for")
        func cachedLayout() {
            let p = Make.playlist(Make.entries(dir: "A", album: "A", count: 2))
            let a = PlaylistLayout.cached(for: p, showAlbumArt: true, trackHeight: 20)
            #expect(a.rowOffsets == PlaylistLayout(playlist: p, showAlbumArt: true, trackHeight: 20).rowOffsets)
            #expect(PlaylistLayout.cached(for: p, showAlbumArt: true, trackHeight: 30).rowOffsets
                    == PlaylistLayout(playlist: p, showAlbumArt: true, trackHeight: 30).rowOffsets)
            #expect(PlaylistLayout.cached(for: p, showAlbumArt: false, trackHeight: 30).rowOffsets
                    == PlaylistLayout(playlist: p, showAlbumArt: false, trackHeight: 30).rowOffsets)
            let other = Make.playlist(Make.entries(dir: "B", album: "B", count: 5))
            #expect(PlaylistLayout.cached(for: other, showAlbumArt: false, trackHeight: 30).rowCount == 6)
        }

        @Test("the row under an offset")
        func rowContaining() {
            let layout = PlaylistLayout(heights: [68, 20, 20])
            #expect(layout.row(containing: 0) == 0)
            #expect(layout.row(containing: 70) == 1)
            #expect(layout.row(containing: 107.5) == 2)
            #expect(layout.row(containing: 108) == nil)
            #expect(layout.row(containing: -1) == nil)
            #expect(PlaylistLayout(heights: []).row(containing: 0) == nil)
        }

        @Test("the rendered rows move in steps, and only the margin is rendered after a jump")
        func rowWindow() {
            let layout = PlaylistLayout(heights: Array(repeating: 20, count: 1000))   // 20 000 points
            func window(_ minY: CGFloat, _ current: Range<Int>) -> Range<Int> {
                layout.window(minY: minY, maxY: minY + 400, current: current, margin: 100, overscan: 300)
            }

            let start = window(2000, 0..<0)
            #expect(start == 95..<126)                                  // nothing to keep: the margin only
            #expect(window(2001, start) == start)                       // still enough
            let placed = window(2030, start)
            #expect(placed == 86..<137)                                 // ran out: placed with the full overscan
            #expect(window(2150, placed) == placed)                     // still has the margin around what is seen
            #expect(window(2250, placed) == 97..<148)                   // the margin ran out: placed again
            #expect(window(9000, placed) == 445..<476)                  // a jump: the margin only
            #expect(window(0, 0..<500) == 0..<36)                       // far more than needed: trimmed
            #expect(PlaylistLayout(heights: []).window(minY: 0, maxY: 400, current: 0..<3, margin: 100,
                                                       overscan: 300) == 0..<0)
        }
    }
}
