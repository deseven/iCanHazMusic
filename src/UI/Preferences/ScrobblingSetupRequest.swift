// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A request to open Preferences > Scrobbling with the sheet for a new service already filled in: what the Last.fm
/// notice (`LastFMRemovalNotice`) does when the user chooses to set up now. It is made before any window exists, so it
/// waits here: `openPreferencesIfRequested()` brings the window up once the app has launched, the Preferences window
/// switches to its Scrobbling tab, and `ScrobbleServiceList` takes the service for its sheet.
@MainActor
@Observable
final class ScrobblingSetupRequest {
    static let shared = ScrobblingSetupRequest()

    /// The service the sheet is to be opened with; nil once it was taken (or if nobody asked).
    private(set) var pending: ScrobbleServiceConfig?

    /// `openWindow(id: preferencesWindowID)`, handed in by `MainWindow` (the action only exists inside a view).
    @ObservationIgnored private var openAction: (() -> Void)?

    private init() {}

    func registerOpenAction(_ open: @escaping () -> Void) {
        openAction = open
    }

    func request(_ service: ScrobbleServiceConfig) {
        pending = service
    }

    /// Hands the service over to whoever shows the sheet; only once.
    func take() -> ScrobbleServiceConfig? {
        defer { pending = nil }
        return pending
    }

    /// Opens the Preferences window if a service is waiting. Call after launch; waits for the main window, which knows
    /// how to open it.
    func openPreferencesIfRequested() async {
        guard pending != nil else { return }
        for _ in 0..<100 where openAction == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let openAction else {
            Log.error("scrobbling: couldn't open Preferences for the setup of Last.fm")
            return
        }
        Log.info("scrobbling: opening Preferences to set up Last.fm")
        NSApp.activate()
        openAction()
    }
}
