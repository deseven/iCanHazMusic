// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation

/// Plays a queue of two audio files (the current track and the one after it) gaplessly and sample-exactly
/// through one `AVAudioPlayerNode`.
///
/// ## Why not `AVPlayer`
/// AVFoundation's FLAC support delivers up to a packet of padding after the last real sample (an audible gap or
/// click between tracks) and its seeking lands at the wrong place in many files. `AVAudioFile` has neither problem,
/// so the file is decoded here and the audio is fed to the player node.
///
/// ## How it works
/// - Every track is decoded by a `TrackDecoder` into one format (stereo float32 at the output's sample rate), so
///   the audio of consecutive tracks is just contiguous buffers, even if the files differ in sample rate or channels.
/// - A feeder keeps `lookahead` seconds of audio scheduled ahead of the playhead; the next track's decoder starts
///   when the current one has delivered its last frame.
/// - The position is derived from the player node's timeline. Nothing relies on completion callbacks. If the
///   feeder ever falls behind (the node plays silence, the timeline moves on) the missing time is detected the
///   next time a buffer is scheduled and subtracted from the position.
/// - Pausing, seeking and stopping fade the output out first and act `fadeDuration` later, and playback starts
///   with a fade-in, so none of them clicks. Changing the queue replaces the player's content (`restart`).
/// - A file that doesn't answer (a network share that went away) never holds up the feeder: a decoder that is dropped
///   releases its wait at once, and one that doesn't deliver within `decoderTimeout` fails (or ends its track there).
/// - After `pauseReleaseDelay` of pause the output is let go of (`releaseIdleOutput`): a running output keeps the Mac
///   from sleeping and holds the device; resuming starts it again from the same position.
///
/// Everything here runs on the main actor; decoding happens on the decoders' queues.
@MainActor
final class PlaybackEngine {
    enum Output: Equatable {
        /// The default output device. The engine starts when playback starts and stops when it ends.
        case device
        /// No device: the audio is pulled with `renderOffline` (for tests).
        case offline(sampleRate: Double)
    }

    enum Event {
        /// The current track's first audio has been decoded and handed to the player (after a start, a seek or any
        /// other restart): its file can be played.
        case started(source: PlaybackSource)
        /// The playhead crossed into the queued next track, which is the current one now.
        case advanced
        /// The queue ran out, playback ended.
        case finished
        /// A track couldn't be played and was dropped. `wasCurrent`: the one playing (the engine is idle then).
        case failed(source: PlaybackSource, wasCurrent: Bool, message: String)
        /// The output can't be started. The engine is idle.
        case deviceError(String)
        /// The chosen output device (`outputDeviceUID`) wasn't there when the output was started: the system default
        /// is used and `outputDeviceUID` is empty now.
        case outputDeviceLost(uid: String)
    }

    /// Time the output takes to fade out before pausing/seeking/stopping.
    static let fadeDuration: Double = 0.03
    /// Seconds of pause after which the output is let go of (`releaseIdleOutput`).
    static let pauseReleaseDelay: Double = 60
    /// Frames rendered at once by `renderOffline` (the engine's maximum).
    nonisolated static let renderSlice = 1024

    var onEvent: ((Event) -> Void)?

    /// Linear gain, 0...1.
    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = min(max(volume, 0), 1) }
    }

    /// Sample rate conversion quality of the tracks opened from now on (what is decoded already stays as it is).
    var resampleQuality = ResampleQuality.default

    /// Seconds of audio the feeder keeps scheduled ahead of the playhead, which is also the time the next track's
    /// file has to open in. Takes effect at once.
    var lookahead: Double

    /// Seconds a file gets to deliver the next piece of audio (opening it included). One that doesn't answer in time
    /// is given up: it fails if nothing of it was played yet, else its track ends there.
    var decoderTimeout: Double = 10

    /// UID of the output device (`AudioOutputDevices`); empty = the system's default, followed when it changes. It is
    /// looked up only when the output is started, and a device that isn't there then is dropped for the system default
    /// (`Event.outputDeviceLost`). A change while the output runs restarts it from the same position.
    var outputDeviceUID = "" {
        didSet {
            guard outputDeviceUID != oldValue, case .device = output, engine.isRunning else { return }
            Log.info("audio output: device changed, restarting the output")
            configurationChanged()
        }
    }

    // MARK: Internals

    private struct Restart {
        var source: PlaybackSource
        /// Where to continue; `nil`: wherever the playhead is when the restart is carried out (a rebuild of the
        /// queue, as opposed to a seek).
        var seconds: Double?
    }

    private final class Slot {
        let source: PlaybackSource
        let decoder: TrackDecoder
        /// Where in the track the first scheduled frame is (seconds from the start of the track, which for a part of a
        /// file is not the start of the file).
        let startSeconds: Double
        /// Timeline frame at which the first scheduled frame plays; valid once `hasScheduled`.
        var startFrame: Int64 = 0
        /// Timeline time lost to starvation inside this track.
        var gapFrames: Int64 = 0
        var scheduledFrames: Int64 = 0
        var endFrame: Int64 = 0
        var hasScheduled = false
        var decodeFinished = false
        var isDecoding = false
        /// Length of the track in seconds, known once its file has been opened.
        var duration: Double?
        /// Format description of the file (`CodecLabel`), known together with `duration`.
        var codec: String?

        init(source: PlaybackSource, startSeconds: Double, decoder: TrackDecoder) {
            self.source = source
            self.startSeconds = startSeconds
            self.decoder = decoder
        }
    }

    /// Replaced when the output has to follow the system default again after it was pinned to a device (`bindOutputDevice`).
    private var engine = AVAudioEngine()
    private var node = AVAudioPlayerNode()
    private let output: Output
    /// The device the engine's output is pinned to (UID); empty = it follows the system default.
    private var boundDeviceUID = ""

    private(set) var sampleRate: Double
    private var format: AVAudioFormat
    /// Buffers scheduled on the player node so far (the node takes them up asynchronously: see `EngineRig`).
    private(set) var scheduledChunks = 0

    /// The current track, followed by the next one once its decoder has been created.
    private var slots: [Slot] = []
    private var nextSource: PlaybackSource?
    private var pendingRestart: Restart?
    private var pendingStop = false
    private(set) var wantsPlaying = false

    /// The paused track after the output was let go of (`releaseIdleOutput`): where to continue on `resume`, and
    /// what was known about the file.
    private struct Parked {
        var restart: Restart
        var duration: Double?
        var codec: String?
    }
    private var parked: Parked?
    private var idleTask: Task<Void, Never>?
    /// Reports CoreAudio calls that block the main thread for long (a device in a bad state).
    private let slowCalls = SlowCallLog()

    /// The player's timeline: total frames scheduled since it was last stopped (plus starvation).
    private var scheduledEnd: Int64 = 0
    /// The timeline position while the node isn't running (paused or not started).
    private var frozenFrame: Int64 = 0

    /// The node's volume is 0 (faded out), and has to be raised again before playing.
    private var faded = false
    private var fadeInFlight = false
    private var fadeFramesRemaining = 0
    private var fadeTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private var renderBuffer: AVAudioPCMBuffer?
    /// The last position read while the device engine was running. Once the system stops the engine (device
    /// change), the player node's timeline is gone and `position` can no longer be computed.
    private var lastPosition: (slot: Slot, seconds: Double)?

    init(output: Output = .device, lookahead: Double = 5) {
        self.output = output
        self.lookahead = lookahead
        switch output {
        case .device:
            sampleRate = 44100
        case .offline(let rate):
            sampleRate = rate
        }
        format = Self.makeFormat(sampleRate: sampleRate)
        engine.attach(node)

        switch output {
        case .offline:
            do {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(Self.renderSlice))
                engine.connect(node, to: engine.mainMixerNode, format: format)
                engine.mainMixerNode.outputVolume = volume
                try engine.start()
                renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.renderSlice))
            } catch {
                Log.error("offline audio engine: \(error.localizedDescription)")
            }
        case .device:
            engine.mainMixerNode.outputVolume = volume
            observeConfigurationChanges()
        }
    }

    private func observeConfigurationChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    private static func makeFormat(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    }

    // MARK: - State

    /// Something is loaded (playing, paused or still starting).
    var isActive: Bool { !pendingStop && (pendingRestart != nil || parked != nil || !slots.isEmpty) }

    /// Seconds into the current track.
    var position: Double {
        if pendingStop { return 0 }
        if let seconds = pendingRestart?.seconds { return seconds }
        if let parked { return parked.restart.seconds ?? 0 }
        guard let slot = slots.first else { return 0 }
        guard slot.hasScheduled else { return slot.startSeconds }
        let frames = max(0, currentFrame() - slot.startFrame - slot.gapFrames)
        // Never past what was scheduled: if decoding falls behind, the player's timeline runs on in silence.
        let seconds = min(slot.startSeconds + Double(frames) / sampleRate,
                          slot.startSeconds + Double(slot.scheduledFrames) / sampleRate)
        if case .device = output, engine.isRunning { lastPosition = (slot, seconds) }
        return seconds
    }

    /// The current track's audio is coming out: it plays, and isn't starting, seeking, waiting for a file that is
    /// late (nothing decoded in time) or released. While this is false the position doesn't move.
    var isAudible: Bool {
        guard wantsPlaying, !pendingStop, pendingRestart == nil, parked == nil,
              let slot = slots.first, slot.hasScheduled else { return false }
        return currentFrame() < scheduledEnd
    }

    /// Audio of the current track has been handed to the player (see `Event.started`).
    var hasCurrentAudio: Bool {
        pendingRestart == nil && !pendingStop && (parked != nil || slots.first?.hasScheduled == true)
    }

    /// Exact length of the current track in seconds, once its file has been opened.
    var duration: Double? {
        guard pendingRestart == nil, !pendingStop else { return nil }
        if let parked { return parked.duration }
        return slots.first?.duration
    }

    /// What the current track's file turned out to be, once it has been opened.
    var currentFile: (source: PlaybackSource, duration: Double, codec: String)? {
        guard pendingRestart == nil, !pendingStop else { return nil }
        if let parked {
            guard let duration = parked.duration, let codec = parked.codec else { return nil }
            return (parked.restart.source, duration, codec)
        }
        guard let slot = slots.first, let duration = slot.duration, let codec = slot.codec else { return nil }
        return (slot.source, duration, codec)
    }

    /// Audio scheduled but not yet played.
    var bufferedSeconds: Double {
        guard isActive else { return 0 }
        return Double(max(0, scheduledEnd - currentFrame())) / sampleRate
    }

    // MARK: - Commands

    /// Plays `source` from `seconds` (into the track), replacing whatever plays now. `next` is queued behind it.
    /// With `playing` off the track is loaded and paused, as if `pause()` had been called right after it started:
    /// the output is let go of after `pauseReleaseDelay` if it isn't resumed by then.
    func start(_ source: PlaybackSource, at seconds: Double = 0, next: PlaybackSource? = nil, playing: Bool = true) {
        wantsPlaying = playing
        pendingStop = false
        nextSource = next
        pendingRestart = Restart(source: source, seconds: max(0, seconds))
        if !playing { armIdleRelease() }
        fadeOutThenCommit()
    }

    /// Plays a whole file.
    func start(_ url: URL, at seconds: Double = 0, next: URL? = nil, playing: Bool = true) {
        start(PlaybackSource(url: url), at: seconds, next: next.map { PlaybackSource(url: $0) }, playing: playing)
    }

    func pause() {
        guard wantsPlaying else { return }
        wantsPlaying = false
        if node.isPlaying { fadeOutThenCommit() }
        armIdleRelease()
    }

    func resume() {
        guard !wantsPlaying, isActive else { return }
        wantsPlaying = true
        idleTask?.cancel()
        idleTask = nil
        if let parked, pendingRestart == nil {
            // The output was let go of during the pause: start it again where the track was left.
            pendingRestart = parked.restart
            commit()
            return
        }
        if fadeInFlight {
            // Changed our mind while fading out: turn around, unless a restart is waiting for the fade to finish
            // (it then starts playing by itself).
            if pendingRestart == nil { cancelFade() }
            return
        }
        if slots.first?.hasScheduled == true, pendingRestart == nil { playNode() }
    }

    func stop() {
        wantsPlaying = false
        nextSource = nil
        pendingRestart = nil
        pendingStop = true
        fadeOutThenCommit()
    }

    /// Returns once the fade-out in progress (if any) is over and what waited for it, such as a stop, is done.
    func waitForFade() async {
        await fadeTask?.value
    }

    /// Moves the current track to `seconds` (at most its last frame).
    func seek(to seconds: Double) {
        guard !pendingStop, let source = pendingRestart?.source ?? slots.first?.source ?? parked?.restart.source else { return }
        var target = max(0, seconds)
        if pendingRestart == nil, let length = parked?.duration ?? slots.first?.duration {
            target = min(target, max(0, length - 1 / sampleRate))
        }
        if parked != nil, pendingRestart == nil {
            parked?.restart.seconds = target   // stays released until it is resumed
            return
        }
        pendingRestart = Restart(source: source, seconds: target)
        fadeOutThenCommit()
    }

    /// Sets the track that follows the current one (`nil`: none).
    func setNext(_ source: PlaybackSource?) {
        guard source != nextSource else { return }
        nextSource = source
        guard pendingRestart == nil, !pendingStop, slots.count > 1 else { return }

        let queued = slots[1]
        if !queued.hasScheduled {
            slots.removeLast()
            queued.decoder.cancel()
        } else if let current = slots.first {
            // Audio of the old next track is already in the player's queue and can't be taken back.
            pendingRestart = Restart(source: current.source, seconds: nil)
            fadeOutThenCommit()
        }
    }

    /// Sets a whole file as the track that follows the current one.
    func setNext(_ url: URL?) {
        setNext(url.map { PlaybackSource(url: $0) })
    }

    // MARK: - Fading and committing

    /// Fades the output out (if anything is audible) and then applies the requested changes.
    private func fadeOutThenCommit() {
        guard node.isPlaying else {
            commit()
            return
        }
        guard !fadeInFlight else { return }   // the pending commit will see the latest request
        fadeInFlight = true
        faded = true
        node.volume = 0
        switch output {
        case .offline:
            fadeFramesRemaining = Int((Self.fadeDuration * sampleRate).rounded(.up))
        case .device:
            fadeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.fadeDuration))
                guard !Task.isCancelled else { return }
                self?.fadeFinished()
            }
        }
    }

    /// Abandons a fade-out in progress: the output comes back up.
    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadeInFlight = false
        fadeFramesRemaining = 0
        node.volume = 1
        faded = false
    }

    private func fadeFinished() {
        guard fadeInFlight else { return }
        fadeInFlight = false
        commit()
    }

    /// Applies what was asked for while (or without) fading out: stop, restart, pause, or a change of mind.
    private func commit() {
        if pendingStop {
            pendingStop = false
            teardown()
        } else if let restart = pendingRestart {
            pendingRestart = nil
            performRestart(restart)
        } else if wantsPlaying {
            if faded, node.isPlaying {   // resumed while fading out
                node.volume = 1
                faded = false
            }
        } else if node.isPlaying {
            frozenFrame = currentFrame()
            slowCalls.measure("AVAudioPlayerNode.pause") { node.pause() }
        }
    }

    private func performRestart(_ restart: Restart) {
        parked = nil
        guard prepareOutput() else {
            teardown()
            onEvent?(.deviceError("can't start the audio output"))
            return
        }
        let seconds = restart.seconds ?? position
        slowCalls.measure("AVAudioPlayerNode.stop") { node.stop() }
        cancelSlots()
        scheduledEnd = 0
        frozenFrame = 0
        slots = [makeSlot(source: restart.source, seconds: seconds)]
        startFeeding()
    }

    private func makeSlot(source: PlaybackSource, seconds: Double) -> Slot {
        let decoder = TrackDecoder(url: source.url, startSeconds: source.start + seconds, endSeconds: source.end,
                                   isPart: !source.isWholeFile, outputFormat: format, resampleQuality: resampleQuality)
        return Slot(source: source, startSeconds: seconds, decoder: decoder)
    }

    private func cancelSlots() {
        for slot in slots { slot.decoder.cancel() }
        slots.removeAll()
        lastPosition = nil
    }

    /// Back to idle: nothing queued, nothing playing. `keepOutput`: the output keeps running, for whoever is told
    /// about it to start the next track without stopping and starting the device in between (`stopOutputIfIdle`).
    private func teardown(keepOutput: Bool = false) {
        fadeTask?.cancel()
        boundaryTask?.cancel()
        feedTask?.cancel()
        idleTask?.cancel()
        fadeTask = nil
        boundaryTask = nil
        feedTask = nil
        idleTask = nil
        fadeInFlight = false
        fadeFramesRemaining = 0
        slowCalls.measure("AVAudioPlayerNode.stop") { node.stop() }
        cancelSlots()
        scheduledEnd = 0
        frozenFrame = 0
        pendingRestart = nil
        parked = nil
        wantsPlaying = false
        if !keepOutput { stopOutput() }
    }

    private func stopOutput() {
        guard case .device = output, engine.isRunning else { return }
        slowCalls.measure("AVAudioEngine.stop") { engine.stop() }
        Log.info("audio output: stopped")
    }

    /// After `teardown(keepOutput: true)` and the event about it: stops the output unless something was started.
    private func stopOutputIfIdle() {
        if !isActive { stopOutput() }
    }

    // MARK: - Releasing the output during a long pause

    private func armIdleRelease() {
        idleTask?.cancel()
        idleTask = nil
        guard case .device = output else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pauseReleaseDelay))
            guard !Task.isCancelled else { return }
            self?.releaseIdleOutput()
        }
    }

    /// Lets go of the output while paused: the player and the decoders are dropped and the device engine is stopped
    /// (which lets the Mac sleep and the device rest); the position is kept, `resume` starts from there with a
    /// fresh output. Does nothing unless paused. Called `pauseReleaseDelay` after a pause; offline (tests) only by hand.
    func releaseIdleOutput() {
        idleTask = nil
        guard !wantsPlaying, !pendingStop, pendingRestart == nil, parked == nil, !fadeInFlight,
              let slot = slots.first else { return }
        parked = Parked(restart: Restart(source: slot.source, seconds: position), duration: slot.duration, codec: slot.codec)
        feedTask?.cancel()
        boundaryTask?.cancel()
        feedTask = nil
        boundaryTask = nil
        slowCalls.measure("AVAudioPlayerNode.stop") { node.stop() }
        cancelSlots()
        scheduledEnd = 0
        frozenFrame = 0
        if case .device = output, engine.isRunning {
            slowCalls.measure("AVAudioEngine.stop") { engine.stop() }
            Log.info("audio output: released after \(Int(Self.pauseReleaseDelay)) s of pause")
        }
    }

    // MARK: - Output

    /// Makes sure the engine runs and the node is connected in the output's format. Offline: always true.
    private func prepareOutput() -> Bool {
        guard case .device = output else { return engine.isRunning }
        if engine.isRunning { return true }

        slowCalls.measure("binding the output device") { bindOutputDevice() }
        let hardware = slowCalls.measure("AVAudioOutputNode.outputFormat") { engine.outputNode.outputFormat(forBus: 0).sampleRate }
        sampleRate = hardware > 0 ? hardware : 44100
        format = Self.makeFormat(sampleRate: sampleRate)
        slowCalls.measure("AVAudioEngine.connect") {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        slowCalls.measure("AVAudioEngine.prepare") { engine.prepare() }
        do {
            try slowCalls.measure("AVAudioEngine.start") { try engine.start() }
            let device = slowCalls.measure("looking up the output device") {
                boundDeviceUID.isEmpty ? AudioOutputDevices.defaultOutput()?.name : AudioOutputDevices.name(ofUID: boundDeviceUID)
            }
            Log.info("audio output: started at \(Int(sampleRate)) Hz on \(device.map { "\"\($0)\"" } ?? "an unknown device")")
            return true
        } catch {
            Log.error("audio engine: \(error.localizedDescription)")
            return false
        }
    }

    /// Points the stopped engine at the chosen device, or back at the system default. The device is looked up now,
    /// not before: one that was unplugged since the last time is given up for the default.
    private func bindOutputDevice() {
        let wanted = outputDeviceUID
        if !wanted.isEmpty {
            if let device = AudioOutputDevices.deviceID(forUID: wanted) {
                boundDeviceUID = wanted   // also on a failure: then the engine is replaced below
                do {
                    try engine.outputNode.auAudioUnit.setDeviceID(device)
                    Log.info("audio output: device \(wanted)")
                    return
                } catch {
                    Log.error("audio output: can't use device \(wanted): \(error.localizedDescription)")
                }
            } else {
                Log.info("audio output: device \(wanted) isn't available, using the system default")
            }
            outputDeviceUID = ""
            onEvent?(.outputDeviceLost(uid: wanted))
        }
        // An output that was pinned to a device doesn't follow the system default any more, only a new engine does.
        if !boundDeviceUID.isEmpty {
            boundDeviceUID = ""
            replaceEngine()
        }
    }

    private func replaceEngine() {
        slowCalls.measure("AVAudioPlayerNode.stop") { node.stop() }
        engine.detach(node)
        engine = AVAudioEngine()
        node = AVAudioPlayerNode()
        engine.attach(node)
        engine.mainMixerNode.outputVolume = min(max(volume, 0), 1)
        faded = false
        observeConfigurationChanges()
    }

    /// The output device or its format changed and the system stopped the engine: continue from the same place.
    private func configurationChanged() {
        guard case .device = output, isActive, let source = pendingRestart?.source ?? slots.first?.source else { return }
        // The engine has already been stopped by the system, so the live position is unreliable (it falls back to
        // the start of the track): use the last one read while it was running.
        var seconds = pendingRestart?.seconds ?? position
        if pendingRestart?.seconds == nil, let last = lastPosition, last.slot === slots.first {
            seconds = last.seconds
        }
        Log.info("audio configuration changed, restarting the output")

        fadeTask?.cancel()
        fadeInFlight = false
        slowCalls.measure("AVAudioEngine.stop") { engine.stop() }
        slowCalls.measure("AVAudioPlayerNode.stop") { node.stop() }
        faded = false
        node.volume = 1
        pendingRestart = Restart(source: source, seconds: seconds)
        commit()
    }

    private func playNode() {
        guard engine.isRunning else { return }
        idleTask?.cancel()
        idleTask = nil
        if faded {
            node.volume = 1   // the mixer ramps this, which is the fade-in
            faded = false
        }
        slowCalls.measure("AVAudioPlayerNode.play") { node.play() }
        armBoundaryTimer()
    }

    // MARK: - Timeline

    /// The player's timeline position in frames (see `scheduledEnd`).
    private func currentFrame() -> Int64 {
        slowCalls.measure("AVAudioPlayerNode.playerTime") {
            if node.isPlaying, let time = node.lastRenderTime, time.isSampleTimeValid,
               let player = node.playerTime(forNodeTime: time), player.isSampleTimeValid {
                return max(0, player.sampleTime)
            }
            return frozenFrame
        }
    }

    // MARK: - Feeding

    private func startFeeding() {
        guard case .device = output, feedTask == nil else { return }
        feedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = self.position   // keeps `lastPosition` fresh
                if await self.feedStep() { continue }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Lets the feeder do everything it can right now. For tests; the app's feeder runs by itself.
    func settle() async {
        while await feedStep() {}
        startPlaybackIfReady()
    }

    /// The slot that needs audio next, creating the next track's slot once the current one is fully decoded.
    private func feedTarget() -> Slot? {
        if let slot = slots.first(where: { !$0.decodeFinished }) { return slot }
        guard slots.count == 1, let source = nextSource else { return nil }
        let slot = makeSlot(source: source, seconds: 0)
        slots.append(slot)
        return slot
    }

    /// Decodes and schedules one chunk if there is room. Returns whether it made progress.
    private func feedStep() async -> Bool {
        guard pendingRestart == nil, !pendingStop, let slot = feedTarget(), !slot.isDecoding else { return false }
        guard Double(scheduledEnd - currentFrame()) < lookahead * sampleRate else { return false }

        slot.isDecoding = true
        let result = await slot.decoder.next(timeout: decoderTimeout)
        slot.isDecoding = false
        // Dropped (restart, stop, new next track) while decoding.
        guard slots.contains(where: { $0 === slot }) else { return true }

        switch result {
        case .chunk(let chunk):
            slot.duration = slot.source.length(inFileOf: chunk.fileDuration)
            slot.codec = chunk.codec
            let first = !slot.hasScheduled
            schedule(chunk.buffer, in: slot)
            startPlaybackIfReady()
            if first, slots.first === slot { onEvent?(.started(source: slot.source)) }
        case .finished(let warning):
            slot.decodeFinished = true
            if slot.scheduledFrames == 0 {
                fail(slot, message: warning ?? "no audio")
            } else {
                if let warning { Log.error("\(slot.source.url.path): \(warning)") }
                armBoundaryTimer()
            }
        case .failed(let message):
            slot.decodeFinished = true
            fail(slot, message: message)
        }
        return true
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, in slot: Slot) {
        // The timeline moves on even when nothing is queued. If it got ahead of what was scheduled, the buffer
        // starts playing now and the difference was silence.
        if node.isPlaying {
            let now = currentFrame()
            if now > scheduledEnd {
                if slot.hasScheduled {
                    slot.gapFrames += now - scheduledEnd
                    Log.error("audio underrun in \(slot.source.url.lastPathComponent): \(Int((Double(now - scheduledEnd) / sampleRate * 1000).rounded())) ms of silence (decoding too slow, slow disk or share?)")
                }
                scheduledEnd = now
            }
        }
        if !slot.hasScheduled {
            slot.hasScheduled = true
            slot.startFrame = scheduledEnd
        }
        scheduledEnd += Int64(buffer.frameLength)
        slot.scheduledFrames += Int64(buffer.frameLength)
        slot.endFrame = scheduledEnd
        scheduledChunks += 1
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    private func startPlaybackIfReady() {
        guard wantsPlaying, !node.isPlaying, !fadeInFlight, pendingRestart == nil, !pendingStop,
              slots.first?.hasScheduled == true else { return }
        playNode()
    }

    private func fail(_ slot: Slot, message: String) {
        let wasCurrent = slots.first === slot
        slots.removeAll { $0 === slot }
        slot.decoder.cancel()
        Log.error("can't play \(slot.source.url.path): \(message)")
        if wasCurrent {
            teardown(keepOutput: true)
        } else {
            nextSource = nil
        }
        onEvent?(.failed(source: slot.source, wasCurrent: wasCurrent, message: message))
        if wasCurrent { stopOutputIfIdle() }
    }

    // MARK: - Track boundaries

    /// Notices that the playhead moved into the next track (or off the end of the queue). Called by whoever
    /// polls the position, and by the timer armed for the expected boundary.
    func poll() {
        guard pendingRestart == nil, !pendingStop else { return }
        while let first = slots.first, first.decodeFinished, first.hasScheduled, currentFrame() >= first.endFrame {
            if slots.count > 1 {
                slots.removeFirst()
                nextSource = nil   // it is the current track now; whoever listens queues the next one
                armBoundaryTimer()
                onEvent?(.advanced)
            } else if nextSource == nil {
                teardown(keepOutput: true)
                onEvent?(.finished)
                stopOutputIfIdle()
                return
            } else {
                return   // the next track's decoder has just been asked for; it is only late
            }
        }
    }

    /// Wakes up when the current track is expected to end, which is when the UI should switch to the next one.
    private func armBoundaryTimer() {
        boundaryTask?.cancel()
        boundaryTask = nil
        guard case .device = output, node.isPlaying, let first = slots.first, first.decodeFinished, first.hasScheduled else { return }
        let remaining = Double(first.endFrame - currentFrame()) / sampleRate
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, remaining) + 0.02))
            guard !Task.isCancelled, let self else { return }
            self.poll()
            self.armBoundaryTimer()
        }
    }

    // MARK: - Offline rendering

    /// Pulls `frames` frames of output (both channels) from the engine, as the device would. Only for
    /// `Output.offline`. Fades and track changes advance with the rendered time. The feeder doesn't run by itself
    /// offline: call `settle()` before rendering and whenever the lookahead may have been used up.
    func renderOffline(_ frames: Int) throws -> [[Float]] {
        guard case .offline = output, let buffer = renderBuffer else { return [[], []] }
        var result: [[Float]] = [[], []]
        result[0].reserveCapacity(frames)
        result[1].reserveCapacity(frames)

        var left = frames
        while left > 0 {
            let count = min(left, Self.renderSlice)
            let status = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
            guard status == .success else { throw RenderError.failed(status.rawValue) }
            let produced = Int(buffer.frameLength)
            for channel in 0..<2 {
                result[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: produced))
            }
            left -= count

            if fadeInFlight {
                fadeFramesRemaining -= count
                if fadeFramesRemaining <= 0 { fadeFinished() }
            }
            poll()
        }
        return result
    }

    enum RenderError: Error { case failed(Int) }
}
