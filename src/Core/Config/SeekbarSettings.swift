// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// How the seek bar of the playback block looks (`now_playing.seekbar_style` in the config; the raw value is what the
/// file holds). Everything but `standard` draws what `Waveform` holds about the track; all of those styles need the same
/// data, so they share one analysis and one stored record, and switching between them is instant.
enum SeekbarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A thin progress bar.
    case standard = "default"
    /// The loudness (RMS) of the track over time as bars.
    case waveformRMS = "waveform_rms"
    /// Two layers: the peaks, and the RMS in front of them.
    case waveformPeakRMS = "waveform_peak_rms"
    /// Three nested layers of the low, mid and high frequencies, in different opacities of one colour.
    case waveformTriBand = "waveform_tri_band"
    /// The RMS bars coloured by the section of the track (verse, chorus, ...), with ticks where the sections change.
    case waveformStructure = "waveform_structure"
    /// Frequency (vertical) over time, as a heat map in the accent colour.
    case spectrogram

    static let `default`: SeekbarStyle = .standard

    var id: String { rawValue }

    /// Whether the style draws the data of `Waveform` (what `WaveformService` makes).
    var usesWaveform: Bool { self != .standard }

    var title: String {
        switch self {
        case .standard: "Default"
        case .waveformRMS: "Waveform (RMS)"
        case .waveformPeakRMS: "Waveform (Peak + RMS)"
        case .waveformTriBand: "Waveform (Tri-band)"
        case .waveformStructure: "Waveform (RMS + Structure)"
        case .spectrogram: "Spectrogram"
        }
    }
}

/// The settings of the seek bar (Preferences > Now Playing), which keeps them in the config. `nil` for `configStore`
/// (tests): defaults, nothing is persisted.
@MainActor
@Observable
final class SeekbarSettings {
    static let shared = SeekbarSettings(configStore: .shared)

    /// Persisted in the config.
    var style: SeekbarStyle {
        didSet {
            guard style != oldValue else { return }
            configStore?.update { $0.nowPlaying.seekbarStyle = style }
            Log.info("seekbar style: \(style.rawValue)")
            onStyleChange?(style)
        }
    }

    /// Called after the style changed (`WaveformService` starts or stops its work, or keeps what it has).
    @ObservationIgnored var onStyleChange: ((SeekbarStyle) -> Void)?

    @ObservationIgnored private let configStore: ConfigStore?

    init(configStore: ConfigStore? = nil) {
        self.configStore = configStore
        style = configStore?.config.nowPlaying.seekbarStyle ?? SeekbarStyle.default
    }
}
