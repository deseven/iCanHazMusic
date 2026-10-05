// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// The hotkey settings (kept in the config, section `hotkeys`) and the custom global hotkeys that follow from them.
///
/// - Every action with a hotkey is registered with the backend and runs on `PlaybackState` when pressed.
/// - A combination can only belong to one action: giving one to an action takes it from the action that had it.
/// - A combination that can't be registered (taken by the system or another app) is reported in `failed`; the
///   other hotkeys are unaffected.
/// - While a hotkey is being recorded (`isRecording`) none are registered, otherwise pressing the combination of an
///   existing one would trigger it instead of being recorded.
///
/// `mediaKeys` is only the setting; reacting to the keys is `SystemMediaControls` (UI), which watches it.
@MainActor
@Observable
final class HotkeyService {
    static let shared = HotkeyService(configStore: .shared, backend: GlobalHotkeyManager.shared, playback: .shared)

    /// The play/pause, next and previous keys control the player. Persisted in the config.
    var mediaKeys = AppConfig.Hotkeys().mediaKeys {
        didSet {
            guard mediaKeys != oldValue else { return }
            configStore.update { $0.hotkeys.mediaKeys = mediaKeys }
            Log.info("media keys: \(mediaKeys ? "on" : "off")")
        }
    }

    /// The hotkey of each action (an action without one isn't in here).
    private(set) var hotkeys: [HotkeyAction: Hotkey] = [:]

    /// Actions whose hotkey couldn't be registered because something else has it already.
    private(set) var failed: Set<HotkeyAction> = []

    /// Hotkeys are off because one is being recorded.
    private(set) var isRecording = false

    /// What the search hotkey does; the search window is UI, which sets this.
    @ObservationIgnored var onSearch: () -> Void = {}

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let backend: HotkeyBackend
    @ObservationIgnored private let playback: PlaybackState
    @ObservationIgnored private var registered: [HotkeyID] = []
    @ObservationIgnored private var started = false

    /// Reads the settings. Nothing is registered before `start()`.
    init(configStore: ConfigStore, backend: HotkeyBackend, playback: PlaybackState) {
        self.configStore = configStore
        self.backend = backend
        self.playback = playback

        let saved = configStore.config.hotkeys
        mediaKeys = saved.mediaKeys
        for action in HotkeyAction.allCases {
            if let hotkey = Hotkey(string: saved[action]) { hotkeys[action] = hotkey }
        }
    }

    /// Registers the hotkeys; from now on changes are applied right away.
    func start() {
        guard !started else { return }
        started = true
        registerAll()
    }

    /// The hotkey of an action in its text form, empty = none.
    func hotkeyString(for action: HotkeyAction) -> String {
        hotkeys[action]?.string ?? ""
    }

    /// Sets (or, with `nil`, removes) the hotkey of an action. If another action had the combination, it loses it.
    func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        guard hotkeys[action] != hotkey else { return }
        if let hotkey {
            for (other, existing) in hotkeys where other != action && existing == hotkey {
                hotkeys[other] = nil
                Log.info("hotkey \(hotkey.string) moved from \"\(other.title)\" to \"\(action.title)\"")
            }
        }
        hotkeys[action] = hotkey

        configStore.update { config in
            for each in HotkeyAction.allCases { config.hotkeys[each] = hotkeys[each]?.string ?? "" }
        }
        registerAll()
    }

    /// A hotkey is being recorded (or isn't any more): the hotkeys are off meanwhile.
    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        registerAll()
    }

    /// Does what the action says.
    func perform(_ action: HotkeyAction) {
        switch action {
        case .search: onSearch()
        case .playPause: playback.playPause()
        case .nextTrack: playback.nextTrack()
        case .previousTrack: playback.previousTrack()
        case .nextAlbum: playback.nextAlbum()
        case .previousAlbum: playback.previousAlbum()
        case .randomTrack: playback.randomTrack()
        case .randomAlbum: playback.randomAlbum()
        case .volumeUp: playback.volumeUp()
        case .volumeDown: playback.volumeDown()
        }
    }

    // MARK: - Registration

    private func registerAll() {
        guard started else { return }
        for id in registered { backend.unregister(id) }
        registered = []

        var failures: Set<HotkeyAction> = []
        if !isRecording {
            for action in HotkeyAction.allCases {
                guard let hotkey = hotkeys[action] else { continue }
                do {
                    registered.append(try backend.register(hotkey) { [weak self] in self?.perform(action) })
                } catch {
                    failures.insert(action)
                    Log.error("can't register \(hotkey.string) for \"\(action.title)\": \(error)")
                }
            }
        } else {
            failures = failed   // not known while off: what was reported stays
        }
        if failures != failed { failed = failures }
    }
}
