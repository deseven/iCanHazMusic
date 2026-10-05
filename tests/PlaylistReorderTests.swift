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
    }
}
