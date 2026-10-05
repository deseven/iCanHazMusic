// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The lyrics sheet on the main window: from the playback block (the track that plays) and from the playlist's
/// context menu (the selected track). One at a time; the window is blocked until it is closed.
@MainActor
enum LyricsSheet {
    private static var panel: NSWindow?

    static func present(_ subject: LyricsView.Subject) {
        guard panel == nil, let parent = Dialogs.hostWindow, parent.isVisible, parent.attachedSheet == nil else { return }
        let hosting = NSHostingController(rootView: LyricsView(subject: subject, close: dismiss))
        hosting.sizingOptions = [.preferredContentSize]
        let panel = NSWindow(contentViewController: hosting)
        panel.styleMask = [.titled]
        self.panel = panel
        parent.beginSheet(panel) { _ in Self.panel = nil }
    }

    private static func dismiss() {
        guard let panel, let parent = panel.sheetParent else { return }
        parent.endSheet(panel)
    }
}
