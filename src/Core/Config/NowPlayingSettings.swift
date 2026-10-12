// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// How the seek bar of the playback block looks (`now_playing.component_options.seekbar_style` in the config; the raw value is what the
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

/// The settings of the now playing block (Preferences > Now Playing: whether it is there, which components it has and
/// in what order, their options: the seek bar style, the texts of Title and Subtitle), which keeps them in the config. `nil` for `configStore` (tests): defaults,
/// nothing is persisted.
///
/// What is hidden isn't done either: `showsArt` and `needsWaveform` are what the album art and the waveform are
/// loaded for. Whoever acts on them hears about changes through `addVisibilityObserver`.
@MainActor
@Observable
final class NowPlayingSettings {
    static let shared = NowPlayingSettings(configStore: .shared)

    /// The block is shown at all. Persisted in the config.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            configStore?.update { $0.nowPlaying.enabled = isEnabled }
            Log.info("now playing block: \(isEnabled ? "on" : "off")")
            visibilityDidChange()
        }
    }

    /// The components of the block. Persisted in the config.
    var layout: NowPlayingLayout {
        didSet {
            guard layout != oldValue else { return }
            configStore?.update { $0.nowPlaying.layout = layout }
            Log.info("now playing layout: \(layout.summary)")
            visibilityDidChange()
        }
    }

    /// The album art is on screen: it is loaded, and sent along with notifications.
    var showsArt: Bool { isEnabled && layout.isVisible(.albumArt) }

    /// The seek bar is on screen.
    var showsSeekbar: Bool { isEnabled && layout.isVisible(.seekbar) }

    /// The waveform of the playing track is wanted: a visual seek bar is on screen.
    var needsWaveform: Bool { showsSeekbar && style.usesWaveform }

    /// Persisted in the config.
    var style: SeekbarStyle {
        didSet {
            guard style != oldValue else { return }
            configStore?.update { $0.nowPlaying.componentOptions.seekbarStyle = style }
            Log.info("seekbar style: \(style.rawValue)")
            onStyleChange?(style)
        }
    }

    /// What the Title shows (`TextTemplate`). Persisted in the config. Not logged: it changes with every key typed.
    var titleTemplate: String {
        didSet {
            guard titleTemplate != oldValue else { return }
            configStore?.update { $0.nowPlaying.componentOptions.title = titleTemplate }
        }
    }

    /// What the Subtitle shows (`TextTemplate`). Persisted in the config.
    var subtitleTemplate: String {
        didSet {
            guard subtitleTemplate != oldValue else { return }
            configStore?.update { $0.nowPlaying.componentOptions.subtitle = subtitleTemplate }
        }
    }

    /// Font size of the Title in percent of the usual size. Persisted in the config. Not logged: a slider drags through it.
    var titleScale: Int {
        didSet {
            guard titleScale != oldValue else { return }
            configStore?.update { $0.nowPlaying.componentOptions.titleScale = titleScale }
        }
    }

    /// Font size of the Subtitle in percent of the usual size. Persisted in the config.
    var subtitleScale: Int {
        didSet {
            guard subtitleScale != oldValue else { return }
            configStore?.update { $0.nowPlaying.componentOptions.subtitleScale = subtitleScale }
        }
    }

    /// The buttons of the Playback Controls, in order, shown or hidden. Persisted in the config.
    var controls: PlaybackControlsLayout {
        didSet {
            guard controls != oldValue else { return }
            configStore?.update { $0.nowPlaying.componentOptions.controls = controls }
            Log.info("playback controls: \(controls.summary)")
        }
    }

    /// Called after the style changed (`WaveformService` starts or stops its work, or keeps what it has).
    @ObservationIgnored var onStyleChange: ((SeekbarStyle) -> Void)?

    @ObservationIgnored private var visibilityObservers: [() -> Void] = []
    @ObservationIgnored private let configStore: ConfigStore?

    init(configStore: ConfigStore? = nil) {
        self.configStore = configStore
        let config = configStore?.config.nowPlaying ?? AppConfig.NowPlaying()
        isEnabled = config.enabled
        layout = config.layout
        style = config.componentOptions.seekbarStyle
        titleTemplate = config.componentOptions.title
        subtitleTemplate = config.componentOptions.subtitle
        titleScale = config.componentOptions.titleScale
        subtitleScale = config.componentOptions.subtitleScale
        controls = config.componentOptions.controls
    }

    /// `observer` is called after the block was turned on or off or its components changed (not necessarily in a way
    /// that matters to the caller: compare `showsArt` and the like).
    func addVisibilityObserver(_ observer: @escaping () -> Void) {
        visibilityObservers.append(observer)
    }

    func resetLayout() {
        layout = .default
    }

    func resetControls() {
        controls = .default
    }

    private func visibilityDidChange() {
        for observer in visibilityObservers { observer() }
    }
}
