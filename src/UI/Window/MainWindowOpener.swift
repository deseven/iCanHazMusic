// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Brings the main window back when something needs it while it is closed (the app keeps running without it, see
/// `WindowSettings.closeQuits`): the File menu's panels, a "go to" from the search window, an update to offer.
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()

    /// `openWindow(id: mainWindowID)`, handed in by `MainWindow` (the action only exists inside a view).
    private var openAction: (() -> Void)?

    private init() {}

    func register(_ open: @escaping () -> Void) {
        openAction = open
    }

    /// The main window was closed: not shown, and not just minimized or hidden together with the app.
    var isClosed: Bool {
        guard !NSApp.isHidden else { return false }
        guard let window = Dialogs.hostWindow else { return true }
        return !window.isVisible && !window.isMiniaturized
    }

    /// Shows the main window (opening it if it was closed), brings it in front and returns it; `nil` if it didn't
    /// come up.
    @discardableResult
    func show() async -> NSWindow? {
        NSApp.activate()
        if let window = Dialogs.hostWindow, window.isVisible || window.isMiniaturized {
            front(window)
            return window
        }

        Log.info("window: reopening the main window")
        openAction?()
        // The window is created (or shown again) by SwiftUI; `WindowPersistence.attach` publishes it as the host.
        for _ in 0..<40 {
            if let window = Dialogs.hostWindow, window.isVisible {
                front(window)
                return window
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let window = Dialogs.hostWindow {
            // SwiftUI kept the window object but didn't show it.
            front(window)
            if window.isVisible { return window }
        }
        Log.error("window: the main window didn't come back")
        return nil
    }

    private func front(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}
