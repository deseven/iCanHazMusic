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
    var isActive: Bool { !pendingStop && (pendingRestart != nil || !slots.isEmpty) }

    /// Seconds into the current track.
    var position: Double {
        if pendingStop { return 0 }
        if let seconds = pendingRestart?.seconds { return seconds }
        guard let slot = slots.first else { return 0 }
        guard slot.hasScheduled else { return slot.startSeconds }
        let frames = max(0, currentFrame() - slot.startFrame - slot.gapFrames)
        var seconds = slot.startSeconds + Double(frames) / sampleRate
        if slot.decodeFinished {
            seconds = min(seconds, slot.startSeconds + Double(slot.scheduledFrames) / sampleRate)
        }
        if case .device = output, engine.isRunning { lastPosition = (slot, seconds) }
        return seconds
    }

    /// Exact length of the current track in seconds, once its file has been opened.
    var duration: Double? {
        pendingRestart == nil && !pendingStop ? slots.first?.duration : nil
    }

    /// What the current track's file turned out to be, once it has been opened.
    var currentFile: (source: PlaybackSource, duration: Double, codec: String)? {
        guard pendingRestart == nil, !pendingStop, let slot = slots.first,
              let duration = slot.duration, let codec = slot.codec else { return nil }
        return (slot.source, duration, codec)
    }

    /// Audio scheduled but not yet played.
    var bufferedSeconds: Double {
        guard isActive else { return 0 }
        return Double(max(0, scheduledEnd - currentFrame())) / sampleRate
    }

    // MARK: - Commands

    /// Plays `source` from `seconds` (into the track), replacing whatever plays now. `next` is queued behind it.
    func start(_ source: PlaybackSource, at seconds: Double = 0, next: PlaybackSource? = nil, playing: Bool = true) {
        wantsPlaying = playing
        pendingStop = false
        nextSource = next
        pendingRestart = Restart(source: source, seconds: max(0, seconds))
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
    }

    func resume() {
        guard !wantsPlaying, isActive else { return }
        wantsPlaying = true
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
        guard !pendingStop, let source = pendingRestart?.source ?? slots.first?.source else { return }
        var target = max(0, seconds)
        if pendingRestart == nil, let length = slots.first?.duration {
            target = min(target, max(0, length - 1 / sampleRate))
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
            node.pause()
        }
    }

    private func performRestart(_ restart: Restart) {
        guard prepareOutput() else {
            teardown()
            onEvent?(.deviceError("can't start the audio output"))
            return
        }
        let seconds = restart.seconds ?? position
        node.stop()
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

    /// Back to idle: nothing queued, nothing playing.
    private func teardown() {
        fadeTask?.cancel()
        boundaryTask?.cancel()
        feedTask?.cancel()
        fadeTask = nil
        boundaryTask = nil
        feedTask = nil
        fadeInFlight = false
        fadeFramesRemaining = 0
        node.stop()
        cancelSlots()
        scheduledEnd = 0
        frozenFrame = 0
        pendingRestart = nil
        wantsPlaying = false
        if case .device = output, engine.isRunning {
            engine.stop()
            Log.info("audio output: stopped")
        }
    }

    // MARK: - Output

    /// Makes sure the engine runs and the node is connected in the output's format. Offline: always true.
    private func prepareOutput() -> Bool {
        guard case .device = output else { return engine.isRunning }
        if engine.isRunning { return true }

        bindOutputDevice()
        let hardware = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = hardware > 0 ? hardware : 44100
        format = Self.makeFormat(sampleRate: sampleRate)
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            Log.info("audio output: started at \(Int(sampleRate)) Hz")
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
        node.stop()
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
        engine.stop()
        node.stop()
        faded = false
        node.volume = 1
        pendingRestart = Restart(source: source, seconds: seconds)
        commit()
    }

    private func playNode() {
        guard engine.isRunning else { return }
        if faded {
            node.volume = 1   // the mixer ramps this, which is the fade-in
            faded = false
        }
        node.play()
        armBoundaryTimer()
    }

    // MARK: - Timeline

    /// The player's timeline position in frames (see `scheduledEnd`).
    private func currentFrame() -> Int64 {
        if node.isPlaying, let time = node.lastRenderTime, time.isSampleTimeValid,
           let player = node.playerTime(forNodeTime: time), player.isSampleTimeValid {
            return max(0, player.sampleTime)
        }
        return frozenFrame
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
        let result = await slot.decoder.next()
        slot.isDecoding = false
        // Dropped (restart, stop, new next track) while decoding.
        guard slots.contains(where: { $0 === slot }) else { return true }

        switch result {
        case .chunk(let chunk):
            slot.duration = slot.source.length(inFileOf: chunk.fileDuration)
            slot.codec = chunk.codec
            schedule(chunk.buffer, in: slot)
            startPlaybackIfReady()
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
            teardown()
        } else {
            nextSource = nil
        }
        onEvent?(.failed(source: slot.source, wasCurrent: wasCurrent, message: message))
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
                teardown()
                onEvent?(.finished)
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
