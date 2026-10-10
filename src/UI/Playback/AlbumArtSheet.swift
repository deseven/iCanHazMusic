// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The sheet on the main window that shows the album art at its original resolution (one image pixel per point,
/// whatever the display's scale), opened by clicking the art in the playback block. Only shrunk, keeping the
/// proportions, if it wouldn't fit in the window. One at a time; the window is blocked until it is closed (Close,
/// Esc, or a click on the window behind).
@MainActor
enum AlbumArtSheet {
    private static var panel: NSWindow?
    private static var outsideClicks: OutsideClickDismisser?

    static func present(_ image: CGImage) {
        guard panel == nil, let parent = Dialogs.hostWindow, parent.isVisible, parent.attachedSheet == nil else { return }
        // The layout rect, not the content rect: the sheet hangs below the title bar/toolbar, which a full-size
        // content view makes part of the latter.
        let content = parent.contentLayoutRect.size
        let limit = AlbumArtSheetView.imageLimit(inWindowContent: content)
        let hosting = NSHostingController(rootView: AlbumArtSheetView(image: image, limit: limit, close: dismiss))
        hosting.sizingOptions = [.preferredContentSize]
        let panel = NSWindow(contentViewController: hosting)
        panel.styleMask = [.titled]
        self.panel = panel
        outsideClicks = OutsideClickDismisser(parent: parent, dismiss: dismiss)
        parent.beginSheet(panel) { _ in
            Self.panel = nil
            Self.outsideClicks?.stop()
            Self.outsideClicks = nil
        }
    }

    private static func dismiss() {
        guard let panel, let parent = panel.sheetParent else { return }
        parent.endSheet(panel)
    }
}

struct AlbumArtSheetView: View {
    let image: CGImage
    /// The most room the image may take.
    let limit: CGSize
    let close: () -> Void

    var body: some View {
        let size = Self.fittedSize(image: CGSize(width: image.width, height: image.height), limit: limit)
        VStack(spacing: 12) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Layout.artSheetPadding)
    }

    /// The room for the image in a window whose content area is this big: what is left after the sheet's own
    /// padding, the button row and the margin kept to the window's edges (never less than `Layout.artSheetMinSide`).
    static func imageLimit(inWindowContent content: CGSize) -> CGSize {
        let around = 2 * (Layout.artSheetPadding + Layout.artSheetWindowMargin)
        return CGSize(
            width: max(content.width - around, Layout.artSheetMinSide),
            height: max(content.height - around - Layout.artSheetButtonRowHeight, Layout.artSheetMinSide))
    }

    /// The image's size in points (= pixels), or, if it doesn't fit in `limit`, shrunk with the proportions kept.
    static func fittedSize(image: CGSize, limit: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(1, limit.width / image.width, limit.height / image.height)
        return CGSize(width: (image.width * scale).rounded(.down), height: (image.height * scale).rounded(.down))
    }
}
