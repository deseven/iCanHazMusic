// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The lyrics sheet on the main window: from the playback block (the track that plays) and from the playlist's
/// context menu (the selected track). One at a time; the window is blocked until it is closed (Close, Esc, or a click on the window behind).
@MainActor
enum LyricsSheet {
    private static var panel: NSWindow?
    private static var outsideClicks: OutsideClickDismisser?

    static func present(_ subject: LyricsView.Subject) {
        guard panel == nil, let parent = Dialogs.hostWindow, parent.isVisible, parent.attachedSheet == nil else { return }
        let hosting = NSHostingController(rootView: LyricsView(subject: subject, close: dismiss))
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
