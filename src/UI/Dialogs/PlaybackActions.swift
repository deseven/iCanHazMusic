// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// What playback has to tell the user about.
@MainActor
enum PlaybackActions {
    /// Playback stopped because track after track couldn't be played (`PlaybackState.onGiveUp`): a sheet on the main
    /// window (reopened if it was closed), and the Dock icon bounces once if the app is in the background.
    static func gaveUp(_ message: String) {
        NSApp.requestUserAttention(.informationalRequest)
        Task {
            var window = Dialogs.hostWindow
            if MainWindowOpener.shared.isClosed { window = await MainWindowOpener.shared.show() }
            await Dialogs.showError(message, title: "Playback Stopped", on: window)
        }
    }
}
