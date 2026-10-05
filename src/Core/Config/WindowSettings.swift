// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// What closing the window does ("Close Quits", Preferences > General, config `general.close_quits`, off by default).
/// Off: the window closes and the app keeps running (playback, hotkeys, media keys, the Dock menu); the window comes
/// back when something needs it. On: closing the last window quits the app.
@MainActor
@Observable
final class WindowSettings {
    static let shared = WindowSettings(configStore: .shared)

    var closeQuits: Bool {
        didSet {
            guard closeQuits != oldValue else { return }
            configStore?.update { $0.general.closeQuits = closeQuits }
            Log.info("close quits: \(closeQuits ? "on" : "off")")
        }
    }

    @ObservationIgnored private let configStore: ConfigStore?

    /// `configStore`: where `closeQuits` is read from and kept; `nil` = default, and nothing is persisted.
    init(configStore: ConfigStore? = nil) {
        self.configStore = configStore
        closeQuits = configStore?.config.general.closeQuits ?? AppConfig.General().closeQuits
    }
}
