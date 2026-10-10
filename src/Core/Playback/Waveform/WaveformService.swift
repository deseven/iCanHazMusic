// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// The waveform of what plays, for the visual seek bar styles (everything but the default one).
///
/// - Only for the playing track, and only while the seek bar style needs it (`SeekbarStyle.usesWaveform`): with the
///   default style nothing is started. No prefetch of the next track, no analysis at import, no crawling of the library.
///   The analysis makes everything every style needs (RMS, peak, bands, sections) in one pass and the record is stored
///   whole, so a second play of the track, or another visual style, is a database lookup.
/// - When a track starts the stored waveform is looked up (`WaveformStore`, keyed by `WaveformKey`); if there is none
///   the file is analysed in the background (`WaveformAnalyzer`) and the result is stored and shown when it is there.
///   A result of a track that is no longer the playing one is dropped (but stored if complete: the user may come
///   back). An incomplete result (a read failed half way) is shown but not stored. One pass at a time, the newest
///   wins: skipping through tracks doesn't queue up work.
/// - A track that couldn't be analysed is remembered until the app quits, so skipping back to it doesn't retry the whole
///   thing every time.
/// - Switching between visual styles changes nothing here (the data is the same). Switching to the default style cancels
///   a running pass and drops `current` from memory; **the store is never cleared**, what was made is used again when a
///   visual style is picked later.
@MainActor
@Observable
final class WaveformService: PlaybackListener {
    static let shared = WaveformService(settings: .shared, store: .shared)

    enum State: Equatable {
        /// Nothing is being done (the style is not Waveform, nothing plays, or the waveform is there).
        case idle
        /// The waveform is being looked up or made.
        case analysing
        /// The track has none (the file can't be read).
        case unavailable
    }

    /// Measures a file; nil if it can't. Cancelling the calling task cancels the pass.
    typealias Analyser = @Sendable (URL) async -> WaveformAnalysis?

    /// The waveform of the track that plays (or is paused), nil if there is none (yet).
    private(set) var current: Waveform?
    private(set) var state: State = .idle

    @ObservationIgnored private let settings: NowPlayingSettings
    @ObservationIgnored private let store: WaveformStore
    @ObservationIgnored private let analyser: Analyser
    @ObservationIgnored private var playing: PlayedTrack?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Identifies the pass whose result may still be published.
    @ObservationIgnored private var token = 0
    /// Keys that couldn't be analysed.
    @ObservationIgnored private var failed = Set<String>()

    init(settings: NowPlayingSettings, store: WaveformStore,
         analyser: @escaping Analyser = { await WaveformAnalyzer.analyse(url: $0) }) {
        self.settings = settings
        self.store = store
        self.analyser = analyser
        settings.onStyleChange = { [weak self] _ in self?.refreshCurrent() }
    }

    /// The style was switched while a track plays: make (or look up) the waveform, or let go of it. Between two visual
    /// styles the waveform that is there (or being made) is kept.
    func refreshCurrent() {
        guard let playing else { return cancel() }
        if settings.style.usesWaveform, current != nil || state == .analysing || state == .unavailable { return }
        begin(playing)
    }

    // MARK: - Playback

    func trackDidStart(_ track: PlayedTrack) {
        playing = track
        begin(track)
    }

    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval) {
        guard playing?.startedAt == track.startedAt else { return }
        playing = nil
        cancel()
    }

    // MARK: - Work

    private func cancel() {
        task?.cancel()
        task = nil
        token += 1
        current = nil
        state = .idle
    }

    private func begin(_ track: PlayedTrack) {
        cancel()
        guard settings.style.usesWaveform, let url = track.url else { return }
        state = .analysing
        let token = self.token
        let store = self.store
        let analyser = self.analyser
        task = Task { [weak self] in
            // Stat and database: off the main thread, a stalled share must not block the UI.
            let (key, stored) = await Self.offMain { () -> (String?, Waveform?) in
                let key = WaveformKey.make(url: url)
                return (key, key.flatMap { store.waveform(for: $0) })
            }
            guard let self, self.token == token else { return }
            guard let key else {
                Log.info("waveform: can't examine \(url.path)")
                self.state = .unavailable
                return
            }
            if let stored {
                self.publish(stored)
                return
            }
            guard !self.failed.contains(key) else {
                self.state = .unavailable
                return
            }

            let started = ContinuousClock.now
            let analysis = await analyser(url)
            if let analysis, analysis.isComplete {
                await Self.offMain { store.store(analysis.waveform, for: key) }
            }
            guard self.token == token else { return }

            guard let analysis else {
                Log.error("waveform: can't analyse \(url.path)")
                self.failed.insert(key)
                self.state = .unavailable
                return
            }
            let seconds = (ContinuousClock.now - started).components
            Log.info("waveform: \(url.lastPathComponent) analysed in "
                + String(format: "%.2f", Double(seconds.seconds) + Double(seconds.attoseconds) / 1e18) + " s"
                + (analysis.isComplete ? "" : ", incomplete (not stored)"))
            self.publish(analysis.waveform)
        }
    }

    private func publish(_ waveform: Waveform) {
        current = waveform
        state = .idle
    }

    /// Runs blocking work on a background queue (not the Swift concurrency pool, which has few threads).
    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}
