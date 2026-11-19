// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A request to open Preferences > Scrobbling with the sheet for a new service already filled in: what the Last.fm
/// notice (`LastFMRemovalNotice`) does when the user chooses to set up now. The Preferences window is opened by an
/// action that only a view has (`openWindow`), so the request waits here until it is registered: the Preferences window
/// then switches to its Scrobbling tab, and `ScrobbleServiceList` takes the service for its sheet.
@MainActor
@Observable
final class ScrobblingSetupRequest {
    static let shared = ScrobblingSetupRequest()

    /// The service the sheet is to be opened with; nil once it was taken (or if nobody asked).
    private(set) var pending: ScrobbleServiceConfig?

    /// `openWindow(id: preferencesWindowID)`, handed in by `MainWindow`.
    @ObservationIgnored private var openAction: (() -> Void)?

    private init() {}

    /// Registering is what opens Preferences for a request that came first.
    func registerOpenAction(_ open: @escaping () -> Void) {
        openAction = open
        openPreferencesIfRequested()
    }

    func request(_ service: ScrobbleServiceConfig) {
        pending = service
        openPreferencesIfRequested()
    }

    /// Hands the service over to whoever shows the sheet; only once.
    func take() -> ScrobbleServiceConfig? {
        defer { pending = nil }
        return pending
    }

    private func openPreferencesIfRequested() {
        guard pending != nil, let openAction else { return }
        Log.info("scrobbling: opening Preferences to set up a service")
        NSApp.activate()
        openAction()
    }
}
