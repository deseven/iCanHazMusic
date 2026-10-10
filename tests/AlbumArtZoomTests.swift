// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Album art zoom")
    struct AlbumArtZoomTests {
        @Test("the art is zoomed to the original size: one image pixel per screen pixel")
        func originalSize() {
            // 1200 px image on a 2x screen = 600 pt; shown at 300 pt (600 px, half of it).
            #expect(AlbumArtView.zoomedSide(imagePixels: 1200, shownSide: 300, scale: 2) == 600)
            // On a 1x screen the same image is 1200 pt.
            #expect(AlbumArtView.zoomedSide(imagePixels: 1200, shownSide: 300, scale: 1) == 1200)
        }

        @Test("nothing is zoomed if the art is shown at less than 10% below the original size (or bigger)")
        func nothingToZoom() {
            // 600 px image on a 2x screen, shown at 270 pt = 540 px = exactly 90%: not less than 10% smaller.
            #expect(AlbumArtView.zoomedSide(imagePixels: 600, shownSide: 270, scale: 2) == nil)
            #expect(AlbumArtView.zoomedSide(imagePixels: 600, shownSide: 269, scale: 2) == CGFloat(300))
            #expect(AlbumArtView.zoomedSide(imagePixels: 600, shownSide: 300, scale: 2) == nil)
            #expect(AlbumArtView.zoomedSide(imagePixels: 600, shownSide: 500, scale: 2) == nil)      // bigger than the image
        }

        @Test("no size, no zoom")
        func degenerate() {
            #expect(AlbumArtView.zoomedSide(imagePixels: 0, shownSide: 300, scale: 2) == nil)
            #expect(AlbumArtView.zoomedSide(imagePixels: 600, shownSide: 0, scale: 2) == nil)
            #expect(AlbumArtView.zoomedSide(imagePixels: 600, shownSide: 300, scale: 0) == nil)
        }

        @Test("the art sheet shows one pixel per point and only shrinks what doesn't fit, keeping the proportions")
        func sheetSize() {
            let limit = CGSize(width: 800, height: 600)
            #expect(AlbumArtSheetView.fittedSize(image: CGSize(width: 500, height: 500), limit: limit) == CGSize(width: 500, height: 500))
            #expect(AlbumArtSheetView.fittedSize(image: CGSize(width: 1200, height: 1200), limit: limit) == CGSize(width: 600, height: 600))
            #expect(AlbumArtSheetView.fittedSize(image: CGSize(width: 1600, height: 400), limit: limit) == CGSize(width: 800, height: 200))
            #expect(AlbumArtSheetView.fittedSize(image: .zero, limit: limit) == .zero)
        }

        @Test("the art sheet leaves room for its padding, the button and the window's edges, but never gets tiny")
        func sheetLimit() {
            let big = AlbumArtSheetView.imageLimit(inWindowContent: CGSize(width: 1000, height: 800))
            #expect(big.width < 1000 && big.height < 800 - Layout.artSheetButtonRowHeight)
            let tiny = AlbumArtSheetView.imageLimit(inWindowContent: CGSize(width: 50, height: 50))
            #expect(tiny == CGSize(width: Layout.artSheetMinSide, height: Layout.artSheetMinSide))
        }
    }
}
