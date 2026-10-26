// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import Foundation
import Observation

/// What the now playing block shows, and the playlist logic of playback: which track follows which.
///
/// The audio itself is played by `PlaybackEngine`, which always holds at most two tracks: the current one and
/// the one after it in the playlist (the next album's first track after the last track of an album), so the
/// transition between them is gapless. The next one is handed over as soon as a track starts. Whenever the user
/// changes what's playing (a new track, next/previous, ...) the engine's queue is replaced.
///
/// Playback runs from a playlist of `PlaylistStore` (`playingPlaylist`), which need not be the one being browsed.
///
/// The `queue` goes before everything else: while it has tracks, the track after the current one is its first, whatever
/// playlist that is in (playback moves over to it when it starts). When it runs out, playback goes on by the playback
/// order in the playlist of the last queued track, or stops (`PlaybackQueue.stopAtEnd`). Whatever the user does that
/// starts something else (a track by hand, previous/next album, a random track or album, stop) drops the queue.
/// The state is purely transitional: it knows the position `(album, track)` in that playlist and a copy of what to
/// display. The one thing that is kept is where playback stands (`AppConfig.Playback.SavedState`: the track and the
/// position in it, playing or paused), so that `restorePlayback` can pick it up at the next launch.
@MainActor
@Observable
final class PlaybackState {
    static let shared = PlaybackState(store: .shared, engine: PlaybackEngine(), configStore: .shared,
                                      listeners: [LastFMService.shared, LyricsService.shared, NotificationService.shared,
                                                                                        WaveformService.shared],
                                      nowPlaying: .shared)

    enum Status { case stopped, playing, paused }

    /// What the now playing block shows about the current track.
    struct TrackInfo {
        let artist: String
        let title: String
        let album: String
        let year: String?
        /// Track number from the tags.
        let number: Int?
        let codec: String
    }

    private typealias Position = TrackPosition

    private struct WeakListener {
        weak var value: PlaybackListener?
    }

    /// A track to play: in the playing playlist, or in `playlist` when that is another one (the user moved the cursor
    /// to the active playlist, see `playbackFollowsCursor`, or the queue has a track of another playlist next).
    /// Playback only switches to that playlist when the track starts. `queued`: the track comes from the queue
    /// (`pos` is then where it was found, and is looked up again when it starts).
    private struct Target: Equatable {
        var pos: Position
        var playlist: String?
        var queued: QueueEntry?

        var foreign: Bool { playlist != nil }
    }

    private(set) var status: Status = .stopped {
        didSet {
            guard status != oldValue else { return }
            // Pausing/resuming while nobody looks: the position still has to be right for whoever asks later
            // (the system's Now Playing), and no tick publishes it then.
            let continuing = oldValue != .stopped && status != .stopped
            if continuing { publishPosition(engine.position) }
            anchor = PositionAnchor(position: continuing ? Self.seconds(engine.position) : 0, isRunning: isAudible)
        }
    }
    private(set) var info: TrackInfo?
    /// Seconds into the current track. Moves in whole seconds (see `positionStep`).
    private(set) var position: Double = 0 {
        didSet { alignAnchor(to: position) }
    }
    /// The position as something that moves by itself while playing, for views that show it continuously: unlike
    /// `position` it only changes on pause, resume, seek, a new track, or when it has drifted from the engine.
    private(set) var anchor = PositionAnchor.stopped
    /// Seconds. 0 while stopped or unknown.
    private(set) var duration: Double = 0
    /// Original album art cut to a square. The only one kept in memory; nil while loading or if there is none.
    private(set) var artwork: CGImage?
    /// The art of the playing album is being looked up (`artwork` is nil meanwhile).
    private(set) var isLoadingArtwork = false

    /// The tracks that play next, see above.
    let queue: PlaybackQueue

    /// Linear gain, 0...1. Persisted in the config.
    var volume = AppConfig.Engine().volume {
        didSet {
            engine.volume = Float(volume)
            guard volume != oldValue else { return }
            configStore?.update { $0.engine.volume = min(max(volume, ConfigLimits.volumeMin), ConfigLimits.volumeMax) }
        }
    }

    /// When a track starts, the selection moves to it. Acted upon by the playlist view; persisted in the config.
    var cursorFollowsPlayback = true {
        didSet {
            guard cursorFollowsPlayback != oldValue else { return }
            configStore?.update { $0.playback.cursorFollowsPlayback = cursorFollowsPlayback }
        }
    }

    /// When the user moves the cursor (`cursorRow`) away from the playing track, the track under it plays after
    /// the current one, instead of the one that follows it in the playlist. This happens once: after that track
    /// has started, playback continues in playlist order until the cursor is moved again (it is the user's
    /// action that is followed, not the cursor's position). The cursor can be in another playlist than the playing
    /// one: playback then moves on to that playlist after the current track. Persisted in the config.
    var playbackFollowsCursor = true {
        didSet {
            guard playbackFollowsCursor != oldValue else { return }
            configStore?.update { $0.playback.playbackFollowsCursor = playbackFollowsCursor }
            cursorRequested = false   // what was selected before the option was on is not a request
            playlistDidChange()
        }
    }

    /// Which track follows the current one. A change replaces the track queued next. Persisted in the config.
    var order = PlaybackOrder.default {
        didSet {
            guard order != oldValue else { return }
            configStore?.update { $0.playback.order = order }
            Log.info("playback order: \(order.rawValue)")
            shuffleNext = nil
            playlistDidChange()
        }
    }

    /// What happens when nothing follows the last track. Persisted in the config.
    var atPlaylistEnd = PlaylistEnd.default {
        didSet {
            guard atPlaylistEnd != oldValue else { return }
            configStore?.update { $0.playback.atPlaylistEnd = atPlaylistEnd }
            Log.info("at playlist end: \(atPlaylistEnd.rawValue)")
            playlistDidChange()
        }
    }

    /// Sample rate conversion quality; applies to the tracks that start from now on. Persisted in the config.
    var resampleQuality = ResampleQuality.default {
        didSet {
            guard resampleQuality != oldValue else { return }
            engine.resampleQuality = resampleQuality
            configStore?.update { $0.engine.resampleQuality = resampleQuality }
            Log.info("resample quality: \(resampleQuality.rawValue)")
        }
    }

    /// Seconds of audio the engine keeps decoded ahead (one of `ConfigLimits.readAheadOptions`); applies at once.
    /// Persisted in the config.
    var readAhead = ConfigLimits.readAheadDefault {
        didSet {
            guard readAhead != oldValue else { return }
            engine.lookahead = Double(readAhead)
            configStore?.update { $0.engine.readAhead = readAhead }
            Log.info("read-ahead buffer: \(readAhead) s")
        }
    }

    /// UID of the output device, empty = the system default. Checked only when the output starts: a device that is
    /// gone then is replaced by the default (and this becomes empty). Persisted in the config.
    var outputDevice = "" {
        didSet {
            guard outputDevice != oldValue else { return }
            engine.outputDeviceUID = outputDevice
            configStore?.update { $0.engine.outputDevice = outputDevice }
            Log.info("output device: \(outputDevice.isEmpty ? "system default" : outputDevice)")
        }
    }

    /// Where playback stands is kept, and `restorePlayback` picks it up at launch ("Restore Playback State", config
    /// `general.restore_playback_state`, on by default). Turning it off forgets what was kept. Persisted in the config.
    var restoresState = AppConfig.General().restorePlaybackState {
        didSet {
            guard restoresState != oldValue else { return }
            configStore?.update { $0.general.restorePlaybackState = restoresState }
            Log.info("restore playback state: \(restoresState ? "on" : "off")")
            saveState()
        }
    }

    /// The row (of the active playlist) the user last clicked or moved to, set by the playlist view. Moving it
    /// onto the playing track (which is what `cursorFollowsPlayback` does) is not a request to jump anywhere.
    var cursorRow: Int? {
        didSet {
            guard cursorRow != oldValue, !placingCursor, playbackFollowsCursor else { return }
            cursorRequested = cursorTarget().map { $0.foreign || $0.pos != currentPos } ?? false
            playlistDidChange()
        }
    }

    /// Puts the cursor on a row of the active playlist (or nowhere) without that being the user's wish: when a
    /// playlist is opened its last played track is selected, which must not make playback jump there. Whatever
    /// cursor request was pending belongs to the playlist shown before and is dropped.
    func placeCursor(at row: Int?) {
        placingCursor = true
        cursorRow = row
        placingCursor = false
        cursorRequested = false
        playlistDidChange()
    }

    /// The row of the active playlist that is playing (or paused), if playback runs from the active playlist.
    var playingRow: Int? {
        guard status != .stopped, let pos = currentPos, store.playingIsActive else { return nil }
        let ranges = store.activePlaylist.trackRows
        guard ranges.indices.contains(pos.album) else { return nil }
        return ranges[pos.album].lowerBound + pos.track
    }

    var isStopped: Bool { status == .stopped }

    /// The current track as a queue entry (the playing playlist's name and the track's ID), if one plays. It is never
    /// in the queue.
    var playingEntry: QueueEntry? {
        guard status != .stopped, let pos = currentPos, let name = store.playingName,
              let id = track(at: pos, in: store.playingPlaylist)?.id else { return nil }
        return QueueEntry(playlist: name, id: id)
    }

    /// The queue has a track that can be played (so the play button has something to start while stopped).
    var hasQueuedTracks: Bool { queueTarget() != nil }

    /// Play has something to do: it resumes, or starts the first queued track or the one under the cursor.
    var canPlay: Bool {
        status != .stopped || hasQueuedTracks || (cursorRow != nil && !store.isLoading)
    }

    /// The exact position in the current track, read from the engine on every call (not observed: `position` only
    /// moves in whole seconds). For views that follow the music closely, such as synchronised lyrics.
    var livePosition: Double {
        guard status != .stopped else { return 0 }
        let time = engine.position
        return time.isFinite ? max(time, 0) : 0
    }

    /// After this many tracks in a row couldn't be played, playback gives up and `onGiveUp` is told.
    static let maxConsecutiveFailures = 10

    /// Called when playback stopped because track after track couldn't be played (a drive or network share that is
    /// gone, most likely); gets the explanation for the user.
    @ObservationIgnored var onGiveUp: ((String) -> Void)?

    /// Whether a window of the app is on screen. Set by the UI (`AppDelegate`). While none is, `position` is not
    /// published by the ticks at all (every change re-renders the views reading it, and nobody sees them); playback
    /// itself (track changes, listeners) goes on. It is brought up to date when a window shows up again.
    @ObservationIgnored var isWatched = true {
        didSet {
            guard isWatched, !oldValue, status != .stopped else { return }
            publishPosition(engine.position)
            alignAnchor(to: Self.seconds(engine.position))
        }
    }

    // MARK: Internals

    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private let store: PlaylistStore
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private let positionStep: Double
    @ObservationIgnored private let configStore: ConfigStore?
    @ObservationIgnored private let nowPlaying: NowPlayingSettings?
    @ObservationIgnored private var listeners: [WeakListener]
    /// A random number in `0..<count` (replaced by tests). The system generator, which is plenty for shuffling.
    @ObservationIgnored var randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    /// The track a shuffle order picked to follow `from`. It is picked once and kept, so that the track queued in
    /// the engine, "next" and whatever asks again in the meantime agree. Dropped whenever the current track changes.
    @ObservationIgnored private var shuffleNext: (from: Position, pos: Position)?
    /// Tracks that failed to open in a row, since one last started playing or the user started one. Playing on to
    /// the next one after a failure could go on forever with a playlist of files that are all gone (it doesn't end by
    /// itself with a shuffle order or "start over"): at `maxConsecutiveFailures` playback gives up.
    @ObservationIgnored private var failures = 0
    /// Set when playback gave up while a track that plays fine was on (only the tracks after it failed): nothing is
    /// queued after it, and when it ends playback stops and `onGiveUp` gets this.
    @ObservationIgnored private var giveUpMessage: String?
    /// The current track, until its audio actually starts (`PlaybackEngine.Event.started`): only then are the
    /// listeners told, so that a file that can't be played is never announced (Last.fm, LRCLIB, notifications).
    @ObservationIgnored private var pendingStart: PendingStart?

    private struct PendingStart {
        let track: PlayedTrack
        let source: PlaybackSource
        let logLine: String
        /// Where in the track it was picked up after a restart of the app (see `restorePlayback`); 0 for a start.
        let resumedAt: Double
        let isRestore: Bool
    }

    /// A track picked up where the last run left it, see `restorePlayback`.
    private struct Resume {
        let seconds: Double
        let paused: Bool
    }

    /// Seconds of playback between two writes of the position to the config while a track plays (replaced by tests).
    @ObservationIgnored var stateSaveInterval = 10.0
    /// The position (seconds) that was last written to the config as where playback stands.
    @ObservationIgnored private var savedPosition = 0.0
    /// The app is quitting with something playing: the track is put aside for the next launch instead of being left
    /// (see `stopAndWait`).
    @ObservationIgnored private var isQuitting = false
    /// The current track was taken from the queue: when nothing is left in it, "Stop at queue end" applies. A track
    /// started in any other way (and dropping the queue) ends that.
    @ObservationIgnored private var playingFromQueue = false
    /// How much of the current track has been listened to (reported to the listener when the track is left).
    @ObservationIgnored private var progress: PlayProgress?

    /// Observed through `playingRow`.
    private var currentPos: Position?
    @ObservationIgnored private var nextPos: Target?
    /// What was handed to the engine as the next track (to check it is still the track meant when it starts).
    @ObservationIgnored private var nextSource: PlaybackSource?
    /// The user moved the cursor to a track that hasn't been played since: it is due next (see `playbackFollowsCursor`).
    @ObservationIgnored private var cursorRequested = false
    @ObservationIgnored private var placingCursor = false
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// What the opened file says about the current track has been compared with the playlist's values.
    @ObservationIgnored private var fileInfoChecked = false

    /// `Album.key` of the album the loaded (or loading) artwork belongs to.
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    /// `tickInterval`: how often the position is refreshed while something plays; `nil` leaves that to `tick()`.
    /// `positionStep`: `position` is only published when it moves into another multiple of this many seconds
    /// (the UI shows whole seconds, and every change re-renders the views reading it, which costs ~1.5% CPU at
    /// 4 updates a second); 0 publishes every change.
    /// `configStore`: where `cursorFollowsPlayback`, `playbackFollowsCursor`, `resampleQuality`, `readAhead`, `outputDevice`,
    /// `volume`, `order`, `atPlaylistEnd` and `restoresState` are read from and kept (and where playback's state is
    /// saved to); `nil` uses the defaults and persists nothing.
    /// `listeners`: told about every track that starts and ends (held weakly).
    /// `queue`: the playback queue; by default a new one that keeps its settings in `configStore`.
    /// `nowPlaying`: the album art is only loaded while it is shown there; `nil` = always.
    init(store: PlaylistStore, engine: PlaybackEngine, tickInterval: Duration? = .milliseconds(250),
         positionStep: Double = 1, configStore: ConfigStore? = nil, listeners: [PlaybackListener] = [],
         queue: PlaybackQueue? = nil, nowPlaying: NowPlayingSettings? = nil) {
        self.store = store
        self.engine = engine
        self.queue = queue ?? PlaybackQueue(configStore: configStore)
        self.tickInterval = tickInterval
        self.positionStep = positionStep
        self.configStore = configStore
        self.nowPlaying = nowPlaying
        self.listeners = listeners.map(WeakListener.init)
        if let settings = configStore?.config.playback {
            cursorFollowsPlayback = settings.cursorFollowsPlayback
            playbackFollowsCursor = settings.playbackFollowsCursor
            order = settings.order
            atPlaylistEnd = settings.atPlaylistEnd
        }
        if let settings = configStore?.config.engine {
            resampleQuality = settings.resampleQuality
            readAhead = settings.readAhead
            outputDevice = settings.outputDevice
            volume = settings.volume
        }
        if let settings = configStore?.config.general {
            restoresState = settings.restorePlaybackState
        }
        engine.volume = Float(volume)
        engine.resampleQuality = resampleQuality
        engine.lookahead = Double(readAhead)
        engine.outputDeviceUID = outputDevice
        engine.onEvent = { [weak self] event in self?.handle(event) }
        self.queue.onChange = { [weak self] in self?.playlistDidChange() }
        nowPlaying?.addVisibilityObserver { [weak self] in self?.artVisibilityDidChange() }
        store.playback = self
    }

    // MARK: - Commands

    /// Starts playing a track of the active playlist, replacing whatever plays now.
    func play(albumIndex: Int, trackIndex: Int) {
        guard !store.isLoading else { return }
        let playlist = store.activePlaylist
        guard playlist.albums.indices.contains(albumIndex),
              playlist.albums[albumIndex].tracks.indices.contains(trackIndex) else { return }

        store.playbackStarted()
        cursorRequested = false   // an explicit choice of a track overrides what was selected before
        dropQueue("a track was started")
        begin(at: Position(album: albumIndex, track: trackIndex))
    }

    /// Starts playing the track of a row of the active playlist; an album header starts its first track.
    func play(row id: Int) {
        guard !store.isLoading else { return }
        let rows = store.activePlaylist.rows
        guard rows.indices.contains(id) else { return }
        play(albumIndex: rows[id].albumIndex, trackIndex: rows[id].trackIndex ?? 0)
    }

    /// Starts a track of any playlist that is in memory: that playlist is opened first. With `wholeAlbum` it is the
    /// first track of the album the track is in. Does nothing if the playlist or the track isn't there (any more).
    func play(trackID: TrackID, inPlaylist name: String, wholeAlbum: Bool = false) {
        guard let playlist = store.playlist(named: name), let pos = playlist.position(of: trackID) else { return }
        store.setActive(name)
        play(albumIndex: pos.album, trackIndex: wholeAlbum ? 0 : pos.track)
    }

    /// Opens a playlist and starts it from its first track (an empty one is only opened).
    func play(playlist name: String) {
        guard store.exists(name) else { return }
        store.setActive(name)
        guard !store.isLoading, store.activePlaylist.trackCount > 0 else { return }
        play(albumIndex: 0, trackIndex: 0)
    }

    func togglePause() {
        switch status {
        case .playing:
            engine.pause()
            status = .paused
            Log.info("playback: paused at \(Self.clock(engine.position))")
            saveState()
        case .paused:
            engine.resume()
            status = .playing
            Log.info("playback: resumed at \(Self.clock(engine.position))")
            saveState()
        case .stopped:
            break
        }
    }

    /// What the play button does: pauses or resumes, and while stopped starts the queue, or without one the track
    /// under the cursor.
    func playPause() {
        if status == .stopped { startFromStopped() } else { togglePause() }
    }

    /// Resumes if paused; while stopped starts the queue, or without one the track under the cursor. Does nothing
    /// while playing.
    func resume() {
        switch status {
        case .playing: break
        case .paused: togglePause()
        case .stopped: startFromStopped()
        }
    }

    private func startFromStopped() {
        guard let target = queueTarget() else {
            playFromCursor()
            return
        }
        cursorRequested = false
        begin(target)
    }

    /// Pauses if playing.
    func pause() {
        if status == .playing { togglePause() }
    }

    private func playFromCursor() {
        guard let row = cursorRow else { return }
        play(row: row)
    }

    /// How much the volume changes with `volumeUp`/`volumeDown`.
    static let volumeStep = 0.05

    func volumeUp() { changeVolume(by: Self.volumeStep) }
    func volumeDown() { changeVolume(by: -Self.volumeStep) }

    private func changeVolume(by delta: Double) {
        // Rounded, so that repeated steps don't pile up floating point noise (0.7000000000000001...).
        let stepped = ((volume + delta) * 100).rounded() / 100
        volume = min(max(stepped, ConfigLimits.volumeMin), ConfigLimits.volumeMax)
    }

    /// Stops, and drops the queue: the user wants it quiet.
    func stop() {
        dropQueue("stopped")
        halt()
    }

    /// Stops without touching the queue, for when playback ends for another reason than the user's wish (a track that
    /// is gone, the playlist playing was deleted, the output failed).
    func halt() {
        playingFromQueue = false
        endProgress(report: !isQuitting)
        pendingStart = nil
        giveUpMessage = nil
        if status != .stopped { Log.info("playback: stopped") }
        status = .stopped
        engine.stop()
        stopTicking()
        currentPos = nil
        nextPos = nil
        shuffleNext = nil
        cursorRequested = false
        dropArtwork()
        info = nil
        position = 0
        duration = 0
        store.playbackEnded()
        if !isQuitting { saveState() }   // nothing plays: nothing to restore
    }

    /// `stop()`, returning once the output has faded out and stopped. For quitting: the process ending in the middle
    /// of the sound pops.
    ///
    /// Where the track was is kept for the next launch (see `restorePlayback`), which then goes on with it. So the
    /// track isn't left: the listeners hear nothing of its end, a scrobble is made once it really is over, and counted
    /// from the position it is picked up at.
    func stopAndWait() async {
        syncWithEngine()
        guard status != .stopped else { return }
        isQuitting = saveState()
        stop()
        isQuitting = false
        await engine.waitForFade()
    }

    /// The track that plays after this one by the playback order (a random one while shuffling, or the one the
    /// cursor asked for). Does nothing on the last track of the playlist, unless it starts over.
    func nextTrack() {
        syncWithEngine()
        guard let pos = currentPos else { return }
        if let next = nextTarget(after: pos) {
            begin(next)
        } else if queueEnded {
            Log.info("playback: reached the end of the queue")
            halt()
        }
    }

    /// The previous track, or the beginning of the current one if it is the first.
    func previousTrack() {
        syncWithEngine()
        guard let pos = currentPos else { return }
        dropQueue("previous track")
        begin(at: preceding(pos) ?? pos)
    }

    /// The first track of the next album, or of a random other one while shuffling. Does nothing in the last album
    /// of the playlist, unless it starts over.
    func nextAlbum() {
        syncWithEngine()
        guard let pos = currentPos, let playlist = store.playingPlaylist else { return }
        dropQueue("next album")
        let next: Position?
        if order.isShuffle {
            next = randomPosition(in: playlist, wholeAlbum: true, excluding: pos, allowCurrent: false)
        } else if pos.album + 1 < playlist.albums.count {
            next = Position(album: pos.album + 1, track: 0)
        } else {
            next = atPlaylistEnd == .startOver ? firstPosition(in: playlist) : nil
        }
        guard let next else { return }
        begin(at: next)
    }

    /// The first track of the previous album (of the current one if it is the first). Going back is always in
    /// playlist order: what played before a shuffled track is not kept.
    func previousAlbum() {
        syncWithEngine()
        guard let pos = currentPos else { return }
        dropQueue("previous album")
        begin(at: Position(album: max(pos.album - 1, 0), track: 0))
    }

    /// Plays a random track of the playing playlist (of the active one while stopped), other than the current one
    /// unless it is the only one. Whatever the playback order is.
    func randomTrack() { playRandom(wholeAlbum: false) }

    /// Plays the first track of a random album, other than the current one unless it is the only one. Whatever the
    /// playback order is.
    func randomAlbum() { playRandom(wholeAlbum: true) }

    private func playRandom(wholeAlbum: Bool) {
        let wasStopped = status == .stopped
        if wasStopped {
            guard !store.isLoading else { return }
        } else {
            syncWithEngine()
        }
        guard let playlist = wasStopped ? store.activePlaylist : store.playingPlaylist else { return }
        let current = wasStopped ? nil : currentPos
        guard let pos = randomPosition(in: playlist, wholeAlbum: wholeAlbum, excluding: current, allowCurrent: true) else {
            return
        }

        dropQueue("random \(wholeAlbum ? "album" : "track")")
        if wasStopped {
            play(albumIndex: pos.album, trackIndex: pos.track)
        } else {
            begin(at: pos)
        }
    }

    /// A random track of `playlist` (`wholeAlbum`: the first track of a random album), never `current` (or its
    /// album), which is the one that played last. If that leaves nothing, it is `current` again with `allowCurrent`,
    /// else `nil`.
    private func randomPosition(in playlist: Playlist, wholeAlbum: Bool, excluding current: Position?,
                                allowCurrent: Bool) -> Position? {
        let count = wholeAlbum ? playlist.albums.count : playlist.trackCount
        guard count > 0 else { return nil }

        // Pick among the candidates without the current one by index, then step over where it would be.
        var currentIndex: Int?
        if let current, playlist.albums.indices.contains(current.album) {
            currentIndex = wholeAlbum
                ? current.album
                : playlist.albums[..<current.album].reduce(0) { $0 + $1.tracks.count } + current.track
        }
        var index: Int
        if let currentIndex, count > 1 {
            index = min(max(randomIndex(count - 1), 0), count - 2)
            if index >= currentIndex { index += 1 }
        } else if currentIndex != nil, !allowCurrent {
            return nil
        } else {
            index = min(max(randomIndex(count), 0), count - 1)
        }

        if wholeAlbum { return Position(album: index, track: 0) }
        var album = 0
        while index >= playlist.albums[album].tracks.count {
            index -= playlist.albums[album].tracks.count
            album += 1
        }
        return Position(album: album, track: index)
    }

    func seek(to seconds: Double) {
        guard status != .stopped, duration > 0 else { return }
        let target = min(max(seconds, 0), max(duration - 0.05, 0))
        position = target
        Log.info("playback: seek to \(Self.clock(target)) of \(Self.clock(duration))")
        engine.seek(to: target)
        saveState(position: target)
    }

    /// What plays after the current track may have changed: the playing playlist got more tracks (they are only
    /// ever added at the end, which keeps the position valid) or the cursor moved. The next track may be a
    /// different one now, or exist at all if the current one was the last.
    func playlistDidChange() {
        guard status != .stopped else { return }
        syncWithEngine()
        guard let pos = currentPos, nextTarget(after: pos) != nextPos else { return }
        prepareNext(after: pos)
    }

    /// The active playlist's content was replaced (tracks removed, tags reloaded, grouping switched) while it is the
    /// one playing: the playing track has to be found again in `new` by its ID; if it is gone, playback stops.
    func playlistWasReplaced(from old: Playlist, to new: Playlist) {
        guard status != .stopped else { return }
        cursorRequested = false   // the rows it pointed at are different now
        guard let pos = currentPos, let id = track(at: pos, in: old)?.id, let moved = new.position(of: id) else {
            halt()
            return
        }

        currentPos = moved
        nextPos = nil
        shuffleNext = nil   // its positions are the old playlist's
        refreshInfo()
        prepareNext(after: moved)
    }

    // MARK: - The play queue

    /// Adds tracks at the end of the queue (the playing one and the ones that are queued already are left out).
    /// Returns how many were added.
    @discardableResult
    func enqueue(_ entries: [QueueEntry]) -> Int {
        let playing = playingEntry
        return queue.append(entries.filter { $0 != playing })
    }

    /// Takes tracks out of the queue.
    func dequeue(_ entries: Set<QueueEntry>) {
        queue.remove(entries)
    }

    /// Empties the queue: playback goes on in the playlist, as if there had been none (and "Stop at queue end" doesn't
    /// apply to the track that plays).
    func clearQueue() {
        playingFromQueue = false
        queue.clear()
        playlistDidChange()
    }

    /// What the user did started something else than the queue, or wants it gone.
    private func dropQueue(_ reason: String) {
        playingFromQueue = false
        queue.clear(because: reason, notify: false)
    }

    /// The first queued track that still exists, as what plays next. `nil` if the queue is off or empty.
    private func queueTarget() -> Target? {
        guard queue.isEnabled else { return nil }
        for entry in queue.entries {
            guard let list = store.playlist(named: entry.playlist), let pos = list.position(of: entry.id) else { continue }
            return Target(pos: pos, playlist: entry.playlist == store.playingName ? nil : entry.playlist, queued: entry)
        }
        return nil
    }

    /// The queue has been played through and "Stop at queue end" is on: nothing follows the track that plays.
    private var queueEnded: Bool {
        queue.isEnabled && queue.stopAtEnd && playingFromQueue
    }

    // MARK: - Saved state

    /// Writes where playback stands to the config (`AppConfig.Playback.SavedState`): the playing track, the position in
    /// it (`seconds`; the engine's by default), playing or paused. With nothing playing, or with `restoresState` off,
    /// what was kept is forgotten instead. Returns whether a state was kept.
    @discardableResult
    private func saveState(position seconds: Double? = nil) -> Bool {
        guard let configStore else { return false }
        guard restoresState, status != .stopped, let pos = currentPos, let name = store.playingName,
              let id = track(at: pos, in: store.playingPlaylist)?.id else {
            configStore.update { $0.playback.state = nil }
            return false
        }
        let time = seconds ?? engine.position
        // Not a number JSON can hold, or not a position at all: the start of the track is the safe answer.
        let position = time.isFinite ? (max(time, 0) * 1000).rounded() / 1000 : 0
        savedPosition = position
        let state = AppConfig.Playback.SavedState(playlist: name, trackID: id, position: position, paused: status == .paused)
        configStore.update { $0.playback.state = state }
        return true
    }

    /// Picks up where the last run left off, if `restoresState` is on and a track played (or was paused) when the app
    /// was quit: that track, from the position it was at, playing or paused as it was. For the launch: it waits for
    /// the playlist of the track to be read.
    ///
    /// Whatever the user does meanwhile (starting a track, pressing stop) wins. A playlist or track that is gone is
    /// forgotten; one that can't be played leaves playback stopped (see `handle`). The queue is not touched.
    func restorePlayback() async {
        guard restoresState, status == .stopped, let configStore,
              let saved = configStore.config.playback.state else { return }
        let playlist = await store.readPlaylist(named: saved.playlist)
        // Stop forgets the state, as does turning the setting off.
        guard status == .stopped, configStore.config.playback.state == saved else { return }
        guard let playlist, let pos = playlist.position(of: saved.trackID), track(at: pos, in: playlist) != nil else {
            Log.info("playback: nothing to restore, the track is not in playlist \"\(saved.playlist)\" any more")
            configStore.update { $0.playback.state = nil }
            return
        }
        begin(Target(pos: pos, playlist: saved.playlist), resume: Resume(seconds: saved.position, paused: saved.paused))
    }

    // MARK: - Engine queue

    private func begin(at pos: Position) {
        begin(Target(pos: pos))
    }

    /// Replaces the engine's queue with the target and the track after it, and plays. A target in another playlist
    /// than the playing one (`playlist`) moves playback over to that playlist. A queued track leaves the queue.
    /// `afterFailure`: playback moves on by itself because the track before couldn't be played (which goes on counting
    /// the failures in a row); anything else starts counting from scratch.
    /// `resume`: the track is picked up there, and paused or not (`restorePlayback`), instead of started.
    private func begin(_ target: Target, afterFailure: Bool = false, resume: Resume? = nil) {
        if !afterFailure { failures = 0 }
        giveUpMessage = nil
        var target = target
        if let entry = target.queued, let pos = store.playlist(named: entry.playlist)?.position(of: entry.id) {
            target.pos = pos   // the playlist may have changed since the target was made
            target.playlist = entry.playlist == store.playingName ? nil : entry.playlist
        }
        if let name = target.playlist {
            guard let list = store.playlist(named: name), track(at: target.pos, in: list) != nil else {
                halt()
                return
            }
            store.playbackStarted(in: name)
        }
        guard let playlist = store.playingPlaylist, let track = track(at: target.pos, in: playlist) else {
            halt()
            return
        }

        let pos = target.pos
        playingFromQueue = false
        if let name = store.playingName, queue.started(QueueEntry(playlist: name, id: track.id)) {
            playingFromQueue = true
        }
        currentPos = pos
        shuffleNext = nil
        nextPos = nextTarget(after: pos)
        nextSource = nextPos.flatMap { self.track(at: $0.pos, in: self.playlist(of: $0)) }?.source
        engine.start(track.source, at: resume?.seconds ?? 0, next: nextSource, playing: resume?.paused != true)

        status = resume?.paused == true ? .paused : .playing
        trackDidChange(how: resume == nil ? "started" : "restored", resume: resume)
        startTicking()
    }

    /// Hands the track following `pos` (if there is one) to the engine.
    private func prepareNext(after pos: Position) {
        guard giveUpMessage == nil, let next = nextTarget(after: pos),
              let track = track(at: next.pos, in: playlist(of: next)) else {
            if nextSource != nil { Log.info("playback: nothing queued next") }
            nextPos = nil
            nextSource = nil
            engine.setNext(nil as PlaybackSource?)
            return
        }
        if nextSource != track.source { Log.info("playback: next up: \(track.path)") }
        nextPos = next
        nextSource = track.source
        engine.setNext(track.source)
    }

    // MARK: - Reacting to the engine

    private func handle(_ event: PlaybackEngine.Event) {
        if case .outputDeviceLost(let uid) = event {
            // Whatever the state: the engine has dropped the device already, so the setting follows.
            if outputDevice == uid { outputDevice = "" }
            return
        }
        guard status != .stopped else { return }
        switch event {
        case .started(let source):
            if pendingStart?.source == source { announceStart() }
            alignAnchor(to: Self.seconds(engine.position))
        case .advanced:
            advanceToNext()
        case .finished:
            if let message = giveUpMessage {
                halt()
                onGiveUp?(message)
                return
            }
            // The engine's queue ran out: the end of the playlist, or (very short tracks) it was refilled too late.
            if let queued = nextPos, queued.foreign || queued.queued != nil {
                begin(queued)
            } else if let last = nextPos?.pos ?? currentPos, let next = nextTarget(after: last) {
                begin(next)
            } else if queueEnded {
                Log.info("playback: reached the end of the queue")
                halt()
                listeners.forEach { $0.value?.queueDidEnd() }
            } else {
                let playlist = store.playingName
                Log.info("playback: reached the end of playlist \"\(playlist ?? "")\"")
                halt()
                if let playlist { listeners.forEach { $0.value?.playlistDidEnd(playlist: playlist) } }
            }
        case .failed(let source, let wasCurrent, let message):
            if wasCurrent, let pending = pendingStart, pending.isRestore, pending.source == source {
                // The track of the last run can't be played (a share that isn't there yet, a file that is gone): music
                // isn't started from the tracks after it, which would only fail one after the other.
                Log.error("playback: can't restore, staying stopped (\(source.url.path): \(message))")
                halt()
                return
            }
            failures += 1
            if failures >= Self.maxConsecutiveFailures {
                giveUp(lastFailed: source, message: message, stopNow: wasCurrent)
                return
            }
            if wasCurrent, let pos = currentPos {
                if let next = nextTarget(after: pos) { begin(next, afterFailure: true) } else { halt() }
            } else if let failed = nextPos, track(at: failed.pos, in: playlist(of: failed))?.source == source {
                if let entry = failed.queued {
                    queue.started(entry)   // the file can't be played: it is not queued any more
                    if let pos = currentPos { prepareNext(after: pos) }
                } else if failed.foreign {
                    cursorRequested = false   // the track asked for can't be played: back to the playing playlist
                    if let pos = currentPos { prepareNext(after: pos) }
                } else {
                    prepareNext(after: failed.pos)
                }
            }
        case .deviceError(let message):
            Log.error("playback: stopped, audio output failed: \(message)")
            halt()
        case .outputDeviceLost:
            break   // handled above
        }
    }

    /// Too many tracks in a row couldn't be played: stop trying. `stopNow`: nothing plays, playback stops at once;
    /// otherwise the current track (which plays fine, only the ones after it failed) plays to its end first.
    private func giveUp(lastFailed source: PlaybackSource, message: String, stopNow: Bool) {
        let count = Self.maxConsecutiveFailures
        Log.error("playback: giving up, \(count) tracks in a row couldn't be played")
        let text = "\(count) tracks in a row couldn't be played. The last one was:\n\n\(source.url.path)\n\n"
            + "\(message.prefix(1).uppercased())\(message.dropFirst())."
        if stopNow {
            halt()
            onGiveUp?(text)
        } else {
            Log.info("playback: stopping after the current track")
            giveUpMessage = text
            if let pos = currentPos { prepareNext(after: pos) }   // queues nothing now
        }
    }

    /// The engine moved on by itself at the end of a track, which is the gapless transition.
    private func advanceToNext() {
        guard var next = nextPos else { return }
        if let entry = next.queued, let pos = store.playlist(named: entry.playlist)?.position(of: entry.id) {
            next.pos = pos   // the playlist may have changed since the engine was given this track
        }
        if let name = next.playlist {
            // The track the cursor asked for or the queue has next is in another playlist: playback moves over to it.
            // (If that changed since, what plays isn't what it was meant to be: stop.)
            guard track(at: next.pos, in: store.playlist(named: name))?.source == nextSource else {
                halt()
                return
            }
            store.playbackStarted(in: name)
        }
        playingFromQueue = false
        if let entry = next.queued {
            queue.started(entry)
            playingFromQueue = true
        }
        currentPos = next.pos
        nextPos = nil
        shuffleNext = nil
        // Normally decoded long before; if it isn't yet (the file is slow to answer), it is announced once it is.
        trackDidChange(how: "gapless transition", audible: engine.hasCurrentAudio)
        prepareNext(after: next.pos)
    }

    /// Lets the engine report a track change that happened since the last look.
    private func syncWithEngine() {
        guard status != .stopped else { return }
        engine.poll()
    }

    /// Refreshes the position and duration shown. Runs periodically while something plays.
    func tick() {
        guard status != .stopped else { return }
        engine.poll()
        guard status != .stopped else { return }   // the poll may have ended playback

        if let exact = engine.duration, exact > 0, abs(exact - duration) > 0.01 { duration = exact }
        checkFileInfo()
        let time = engine.position
        guard time.isFinite, time >= 0 else { return }
        progress?.observe(position: time)
        if restoresState, status == .playing, abs(time - savedPosition) >= stateSaveInterval {
            saveState(position: time)
        }
        guard isWatched else { return }
        publishPosition(time)
        alignAnchor(to: time)
    }

    /// How far the position may be from where the anchor extrapolates before the anchor is replaced.
    private static let anchorTolerance = 0.5

    /// The position moves on now: playing, and the engine has audio of the track coming out (not while the file is
    /// still being opened, after a seek, or while decoding is behind).
    private var isAudible: Bool {
        status == .playing && engine.isAudible
    }

    /// Keeps `anchor` true to `time`: replaced when it was made for another state of playback or has drifted off.
    private func alignAnchor(to time: Double) {
        let running = isAudible
        if anchor.isRunning == running,
           abs(anchor.position(at: ProcessInfo.processInfo.systemUptime) - time) <= Self.anchorTolerance { return }
        anchor = PositionAnchor(position: time, isRunning: running)
    }

    private static func seconds(_ time: Double) -> Double {
        time.isFinite ? max(time, 0) : 0
    }

    /// Sets `position` if it moved into another multiple of `positionStep` seconds (any change with a step of 0).
    private func publishPosition(_ time: Double) {
        guard time.isFinite, time >= 0 else { return }
        let step = positionStep
        let moved = step > 0
            ? (time / step).rounded(.down) != (position / step).rounded(.down)
            : abs(time - position) > 0.01
        if moved { position = time }
    }

    /// Once per track: the duration and format description that the opened file gives are more reliable than what
    /// the tags said when the track was added. If they differ, the playlist gets the new values.
    private func checkFileInfo() {
        guard !fileInfoChecked, let file = engine.currentFile, let pos = currentPos,
              let playlist = store.playingPlaylist, let track = track(at: pos, in: playlist),
              track.source == file.source else { return }
        fileInfoChecked = true

        let durationDiffers = track.duration.map { abs($0 - file.duration) > Self.durationTolerance } ?? true
        guard durationDiffers || track.codec != file.codec else { return }
        store.updateTrack(id: track.id, duration: file.duration, codec: file.codec)
        refreshInfo()
    }

    /// Tags give durations that are a bit off all the time (MP3 padding, FLAC blocks); only a bigger
    /// difference is worth correcting.
    private static let durationTolerance = 0.5

    private func startTicking() {
        guard tickInterval != nil, tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.tickInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }


    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Current track

    /// Fills in everything shown about the (new) current track. The listeners are told when its audio starts: at once
    /// if `audible`, else on `PlaybackEngine.Event.started`. `resume`: the track was picked up in the middle.
    private func trackDidChange(how: String, audible: Bool = false, resume: Resume? = nil) {
        endProgress()
        pendingStart = nil
        // The request is served
        if cursorRequested, store.playingIsActive, cursorTarget()?.pos == currentPos { cursorRequested = false }
        guard let pos = currentPos, let playlist = store.playingPlaylist,
              let track = track(at: pos, in: playlist) else { return }
        let album = playlist.albums[pos.album]

        store.setLastPlayed(track.id)
        fileInfoChecked = false
        info = TrackInfo(artist: track.artist, title: track.title, album: album.title,
                         year: album.year, number: track.number, codec: track.codec)
        let resumedAt = resume?.seconds ?? 0
        position = resumedAt
        duration = track.duration ?? 0
        loadArtworkIfNeeded(for: album, playing: pos.track)
        saveState(position: resumedAt)

        let played = PlayedTrack(artist: track.artist, title: track.title, album: album.title,
                                 duration: track.duration ?? 0, startedAt: Date(), coverKey: album.key, url: track.url, cue: track.cue)
        let logLine = "playback: \(how)\(resume.map { " at \(Self.clock($0.seconds))\($0.paused ? ", paused" : "")" } ?? ""): "
            + "\(track.artist) – \(track.title) [\(album.title)], "
            + "\(track.codec.isEmpty ? "format unknown" : track.codec), playlist \"\(store.playingName ?? "")\", \(track.path)"
        pendingStart = PendingStart(track: played, source: track.source, logLine: logLine,
                                    resumedAt: resumedAt, isRestore: resume != nil)
        if audible { announceStart() }
    }

    /// The current track's audio has started: now it counts as played, for the log and the listeners.
    private func announceStart() {
        guard let pending = pendingStart else { return }
        pendingStart = nil
        failures = 0
        var played = pending.track
        // A track picked up in the middle started that long ago.
        played.startedAt = Date().addingTimeInterval(-pending.resumedAt)
        Log.info(pending.logLine)
        progress = PlayProgress(track: played, resumedAt: pending.resumedAt)
        for listener in listeners { listener.value?.trackDidStart(played) }
    }

    /// The current track is left (another one starts, or playback stops): the listener hears how far it got.
    /// Runs before `duration` is replaced, so it is still the one of the track that ends.
    /// `report` off: the listeners aren't told, the track is only put aside (see `stopAndWait`).
    private func endProgress(report: Bool = true) {
        guard let finished = progress else { return }
        progress = nil
        var track = finished.track
        if duration > 0 { track.duration = duration }
        let listened = finished.listened(ofDuration: track.duration)
        Log.info("playback: left \(track.artist) – \(track.title), listened to \(Self.clock(listened)) of \(Self.clock(track.duration))"
            + (report ? "" : ", to be picked up at the next launch"))
        guard report else { return }
        for listener in listeners { listener.value?.trackDidEnd(track, playedSeconds: listened) }
    }

    /// `3:05` for log messages.
    private static func clock(_ seconds: Double) -> String {
        NotificationService.formatDuration(seconds.isFinite ? seconds : 0)
    }

    /// Shows the playlist's current values of the current track again, without touching the position.
    private func refreshInfo() {
        guard let pos = currentPos, let playlist = store.playingPlaylist, let track = track(at: pos, in: playlist) else { return }
        let album = playlist.albums[pos.album]
        info = TrackInfo(artist: track.artist, title: track.title, album: album.title,
                         year: album.year, number: track.number, codec: track.codec)
        loadArtworkIfNeeded(for: album, playing: pos.track)
    }

    /// Loads the original art of the album, unless it is the one already loaded (or loading), which is the case
    /// for every track change within an album.
    private func loadArtworkIfNeeded(for album: Album, playing trackIndex: Int) {
        guard nowPlaying?.showsArt ?? true else { return }
        let key = album.key
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        isLoadingArtwork = true
        artworkTask?.cancel()

        let directory = album.directory
        let others = album.tracks.indices.lazy.filter { $0 != trackIndex }.prefix(2).map { album.tracks[$0].url }
        let files = [album.tracks[trackIndex].url] + others

        artworkTask = Task { [weak self] in
            let image = await PlaybackArtwork.load(directory: directory, embeddedFrom: files)
            guard !Task.isCancelled, let self, self.artworkKey == key else { return }
            self.artwork = image
            self.isLoadingArtwork = false
        }
    }

    /// Lets go of the art, and of the work to load it.
    private func dropArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = nil
        artwork = nil
        isLoadingArtwork = false
    }

    /// The now playing block got or lost its album art (or went away altogether): load the art of what plays now, or
    /// drop it from memory.
    private func artVisibilityDidChange() {
        if nowPlaying?.showsArt ?? true {
            if artworkKey == nil { refreshInfo() }
        } else if artworkKey != nil {
            dropArtwork()
        }
    }

    // MARK: - Playlist navigation

    private func track(at pos: Position, in playlist: Playlist?) -> Track? {
        guard let playlist, playlist.albums.indices.contains(pos.album),
              playlist.albums[pos.album].tracks.indices.contains(pos.track) else { return nil }
        return playlist.albums[pos.album].tracks[pos.track]
    }

    /// The track that plays after `pos`: the first queued one; with the queue played through, none if
    /// "Stop at queue end" is on; else the one the user moved the cursor to if `playbackFollowsCursor` is on
    /// (an album header stands for its first track), otherwise `orderedNext(after:)`.
    private func nextTarget(after pos: Position) -> Target? {
        if let queued = queueTarget() { return queued }
        if queueEnded { return nil }
        if playbackFollowsCursor, cursorRequested, let target = cursorTarget(), target.foreign || target.pos != pos {
            return target
        }
        return orderedNext(after: pos).map { Target(pos: $0) }
    }

    /// The track that follows `pos` by the playback order, and at the end of the playlist by `atPlaylistEnd`.
    private func orderedNext(after pos: Position) -> Position? {
        guard let playlist = store.playingPlaylist, playlist.albums.indices.contains(pos.album) else { return nil }
        switch order {
        case .standard:
            if let next = following(pos) { return next }
            return atPlaylistEnd == .startOver ? firstPosition(in: playlist) : nil
        case .trackShuffle:
            return shuffled(after: pos, in: playlist, wholeAlbum: false)
        case .albumShuffle:
            if pos.track + 1 < playlist.albums[pos.album].tracks.count {
                return Position(album: pos.album, track: pos.track + 1)
            }
            return shuffled(after: pos, in: playlist, wholeAlbum: true)
        }
    }

    /// The random pick that follows `pos`, made once (see `shuffleNext`). With nothing else to pick from, it is
    /// the end of the playlist: nothing, or with `startOver` the same one again.
    private func shuffled(after pos: Position, in playlist: Playlist, wholeAlbum: Bool) -> Position? {
        if let kept = shuffleNext, kept.from == pos, track(at: kept.pos, in: playlist) != nil { return kept.pos }
        var picked = randomPosition(in: playlist, wholeAlbum: wholeAlbum, excluding: pos, allowCurrent: false)
        if picked == nil, atPlaylistEnd == .startOver {
            picked = randomPosition(in: playlist, wholeAlbum: wholeAlbum, excluding: pos, allowCurrent: true)
        }
        shuffleNext = picked.map { (from: pos, pos: $0) }
        return picked
    }

    private func firstPosition(in playlist: Playlist) -> Position? {
        guard let first = playlist.albums.first, !first.tracks.isEmpty else { return nil }
        return Position(album: 0, track: 0)
    }

    /// The playlist a target is in.
    private func playlist(of target: Target) -> Playlist? {
        if let name = target.playlist { return store.playlist(named: name) }
        return store.playingPlaylist
    }

    /// `cursorRow` as a track of the active playlist (`foreign` if playback runs from another one).
    private func cursorTarget() -> Target? {
        guard status != .stopped, let row = cursorRow, !store.isLoading else { return nil }
        let rows = store.activePlaylist.rows
        guard rows.indices.contains(row) else { return nil }
        return Target(pos: Position(album: rows[row].albumIndex, track: rows[row].trackIndex ?? 0),
                      playlist: store.playingIsActive ? nil : store.activeName)
    }

    /// The track that plays after `pos` in playlist order: the next one of the album, else the first of the
    /// next album.
    private func following(_ pos: Position) -> Position? {
        guard let playlist = store.playingPlaylist, playlist.albums.indices.contains(pos.album) else { return nil }
        if pos.track + 1 < playlist.albums[pos.album].tracks.count {
            return Position(album: pos.album, track: pos.track + 1)
        }
        if pos.album + 1 < playlist.albums.count {
            return Position(album: pos.album + 1, track: 0)
        }
        return nil
    }

    private func preceding(_ pos: Position) -> Position? {
        guard let playlist = store.playingPlaylist else { return nil }
        if pos.track > 0 { return Position(album: pos.album, track: pos.track - 1) }
        if pos.album > 0 {
            return Position(album: pos.album - 1, track: playlist.albums[pos.album - 1].tracks.count - 1)
        }
        return nil
    }
}
