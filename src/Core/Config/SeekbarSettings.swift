// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// How the seek bar of the playback block looks (`playback.seekbar_style` in the config; the raw value is what the
/// file holds). More styles may follow, so this is a style and not a switch.
enum SeekbarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A thin progress bar.
    case standard = "default"
    /// The loudness of the track over time as bars, see `Waveform`.
    case waveform

    static let `default`: SeekbarStyle = .standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Default"
        case .waveform: "Waveform"
        }
    }
}

/// The settings of the seek bar (Preferences > Playback), which keeps them in the config. `nil` for `configStore`
/// (tests): defaults, nothing is persisted.
@MainActor
@Observable
final class SeekbarSettings {
    static let shared = SeekbarSettings(configStore: .shared)

    /// Persisted in the config.
    var style: SeekbarStyle {
        didSet {
            guard style != oldValue else { return }
            configStore?.update { $0.playback.seekbarStyle = style }
            Log.info("seekbar style: \(style.rawValue)")
            onStyleChange?(style)
        }
    }

    /// Called after the style changed (`WaveformService` starts or stops its work).
    @ObservationIgnored var onStyleChange: ((SeekbarStyle) -> Void)?

    @ObservationIgnored private let configStore: ConfigStore?

    init(configStore: ConfigStore? = nil) {
        self.configStore = configStore
        style = configStore?.config.playback.seekbarStyle ?? SeekbarStyle.default
    }
}
