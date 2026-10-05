// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// The UI side of connecting to and disconnecting from Last.fm: the sheet while waiting, and the alerts. They attach
/// to `window` (the Preferences window, where the buttons are).
@MainActor
enum LastFMActions {
    private static let alertTitle = "Last.fm"

    static func connect(on window: NSWindow?) async {
        let service = LastFMService.shared
        guard let window, !service.isConnected, !service.isAuthorizing else { return }

        let sheet = LastFMAuthSheet(onAbort: { service.abortConnecting() })
        sheet.present(on: window)
        let outcome = await service.connect(openURL: { NSWorkspace.shared.open($0) })
        await sheet.dismiss()

        switch outcome {
        case .connected(let session):
            await Dialogs.showInfo("Successfully connected last.fm as user \(session.username).",
                                   title: alertTitle, on: window)
        case .failed(let message):
            await Dialogs.showError(message, title: "Couldn't Connect to Last.fm", on: window)
        case .aborted:
            break
        }
    }

    static func disconnect(on window: NSWindow?) async {
        let confirmed = await Dialogs.confirm(
            title: "Disconnect Last.fm?",
            message: "Playback will no longer be sent to Last.fm. Tracks that are still waiting to be sent are lost.",
            confirmTitle: "Disconnect",
            destructive: true,
            on: window
        )
        if confirmed { LastFMService.shared.disconnect() }
    }

    /// Last.fm refused the session: tell the user, and bounce the Dock icon until they notice.
    static func connectionLost(_ message: String) {
        NSApp.requestUserAttention(.criticalRequest)
        Task { await Dialogs.showError(message, title: "Last.fm Disconnected") }
    }
}
