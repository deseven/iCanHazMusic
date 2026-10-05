import CoreGraphics
import Foundation
import Observation

/// What the playback block shows, and the playlist logic of playback: which track follows which.
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
/// The state is purely transitional:
/// it knows the position `(album, track)` in that playlist and a copy of what to display, nothing is persisted.
@MainActor
@Observable
final class PlaybackState {
    static let shared = PlaybackState(store: .shared, engine: PlaybackEngine(), configStore: .shared,
                                      listeners: [LastFMService.shared, LyricsService.shared, NotificationService.shared])

    enum Status { case stopped, playing, paused }

    /// What the playback block shows about the current track.
    struct TrackInfo {
        let artist: String
        let title: String
        let album: String
        let year: String?
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

    private(set) var status: Status = .stopped
    private(set) var info: TrackInfo?
    /// Seconds into the current track.
    private(set) var position: Double = 0
    /// Seconds. 0 while stopped or unknown.
    private(set) var duration: Double = 0
    /// Original album art cut to a square. The only one kept in memory; nil while loading or if there is none.
    private(set) var artwork: CGImage?
    /// The art of the playing album is being looked up (`artwork` is nil meanwhile).
    private(set) var isLoadingArtwork = false

    /// The tracks that play next, see above.
    let queue: PlaybackQueue

    /// Linear gain, 0...1. Persisted in the config.
    var volume = AppConfig.Playback().volume {
        didSet {
            engine.volume = Float(volume)
            guard volume != oldValue else { return }
            configStore?.update { $0.playback.volume = min(max(volume, ConfigLimits.volumeMin), ConfigLimits.volumeMax) }
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
            configStore?.update { $0.playback.resampleQuality = resampleQuality }
            Log.info("resample quality: \(resampleQuality.rawValue)")
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

    // MARK: Internals

    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private let store: PlaylistStore
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private let positionStep: Double
    @ObservationIgnored private let configStore: ConfigStore?
    @ObservationIgnored private var listeners: [WeakListener]
    /// A random number in `0..<count` (replaced by tests). The system generator, which is plenty for shuffling.
    @ObservationIgnored var randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    /// The track a shuffle order picked to follow `from`. It is picked once and kept, so that the track queued in
    /// the engine, "next" and whatever asks again in the meantime agree. Dropped whenever the current track changes.
    @ObservationIgnored private var shuffleNext: (from: Position, pos: Position)?
    /// Tracks that failed to open since one last played. Playing on to the next one after a failure could go on
    /// forever with a playlist of files that are all gone, as it doesn't end by itself with a shuffle order or
    /// "start over".
    @ObservationIgnored private var failures = 0
    /// The current track was taken from the queue: when nothing is left in it, "Stop at queue end" applies. A track
    /// started in any other way (and dropping the queue) ends that.
    @ObservationIgnored private var playingFromQueue = false
    /// How much of the current track has been listened to (reported to the listener when the track is left).
    @ObservationIgnored private var progress: PlayProgress?

    /// Observed through `playingRow`.
    private var currentPos: Position?
    @ObservationIgnored private var nextPos: Target?
    /// The file handed to the engine as the next one (to check it is still the track meant when it starts).
    @ObservationIgnored private var nextURL: URL?
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
    /// `configStore`: where `cursorFollowsPlayback`, `playbackFollowsCursor`, `resampleQuality`, `volume`, `order` and
    /// `atPlaylistEnd` are read from and kept; `nil` uses
    /// the defaults and persists nothing.
    /// `listeners`: told about every track that starts and ends (held weakly).
    /// `queue`: the playback queue; by default a new one that keeps its settings in `configStore`.
    init(store: PlaylistStore, engine: PlaybackEngine, tickInterval: Duration? = .milliseconds(250),
         positionStep: Double = 1, configStore: ConfigStore? = nil, listeners: [PlaybackListener] = [],
         queue: PlaybackQueue? = nil) {
        self.store = store
        self.engine = engine
        self.queue = queue ?? PlaybackQueue(configStore: configStore)
        self.tickInterval = tickInterval
        self.positionStep = positionStep
        self.configStore = configStore
        self.listeners = listeners.map(WeakListener.init)
        if let settings = configStore?.config.playback {
            cursorFollowsPlayback = settings.cursorFollowsPlayback
            playbackFollowsCursor = settings.playbackFollowsCursor
            resampleQuality = settings.resampleQuality
            volume = settings.volume
            order = settings.order
            atPlaylistEnd = settings.atPlaylistEnd
        }
        engine.volume = Float(volume)
        engine.resampleQuality = resampleQuality
        engine.onEvent = { [weak self] event in self?.handle(event) }
        self.queue.onChange = { [weak self] in self?.playlistDidChange() }
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
        failures = 0
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
        case .paused:
            engine.resume()
            status = .playing
            Log.info("playback: resumed at \(Self.clock(engine.position))")
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
        failures = 0
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
        endProgress()
        if status != .stopped { Log.info("playback: stopped") }
        status = .stopped
        engine.stop()
        stopTicking()
        currentPos = nil
        nextPos = nil
        shuffleNext = nil
        cursorRequested = false
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = nil
        artwork = nil
        isLoadingArtwork = false
        info = nil
        position = 0
        duration = 0
        store.playbackEnded()
    }

    /// `stop()`, returning once the output has faded out and stopped. For quitting: the process ending in the middle
    /// of the sound pops.
    func stopAndWait() async {
        guard status != .stopped else { return }
        stop()
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

    // MARK: - Engine queue

    private func begin(at pos: Position) {
        begin(Target(pos: pos))
    }

    /// Replaces the engine's queue with the target and the track after it, and plays. A target in another playlist
    /// than the playing one (`playlist`) moves playback over to that playlist. A queued track leaves the queue.
    private func begin(_ target: Target) {
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
        nextURL = nextPos.flatMap { self.track(at: $0.pos, in: self.playlist(of: $0)) }?.url
        engine.start(track.url, next: nextURL)

        status = .playing
        trackDidChange(how: "started")
        startTicking()
    }

    /// Hands the track following `pos` (if there is one) to the engine.
    private func prepareNext(after pos: Position) {
        guard let next = nextTarget(after: pos), let track = track(at: next.pos, in: playlist(of: next)) else {
            if nextURL != nil { Log.info("playback: nothing queued next") }
            nextPos = nil
            nextURL = nil
            engine.setNext(nil)
            return
        }
        if nextURL != track.url { Log.info("playback: next up: \(track.url.path)") }
        nextPos = next
        nextURL = track.url
        engine.setNext(track.url)
    }

    // MARK: - Reacting to the engine

    private func handle(_ event: PlaybackEngine.Event) {
        guard status != .stopped else { return }
        switch event {
        case .advanced:
            advanceToNext()
        case .finished:
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
        case .failed(let url, let wasCurrent, _):
            failures += 1
            if failures > 4 * max(store.playingPlaylist?.trackCount ?? 0, 1) {
                Log.error("playback: stopped, the tracks keep failing to open")
                halt()
                return
            }
            if wasCurrent, let pos = currentPos {
                if let next = nextTarget(after: pos) { begin(next) } else { halt() }
            } else if let failed = nextPos, track(at: failed.pos, in: playlist(of: failed))?.url == url {
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
            guard track(at: next.pos, in: store.playlist(named: name))?.url == nextURL else {
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
        trackDidChange(how: "gapless transition")
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
        if time > 0 { failures = 0 }
        progress?.observe(position: time)
        let moved = positionStep > 0
            ? (time / positionStep).rounded(.down) != (position / positionStep).rounded(.down)
            : abs(time - position) > 0.01
        if moved { position = time }
    }

    /// Once per track: the duration and format description that the opened file gives are more reliable than what
    /// the tags said when the track was added. If they differ, the playlist gets the new values.
    private func checkFileInfo() {
        guard !fileInfoChecked, let file = engine.currentFile, let pos = currentPos,
              let playlist = store.playingPlaylist, let track = track(at: pos, in: playlist),
              track.url == file.url else { return }
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
        guard let tickInterval, tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
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

    /// Fills in everything shown about the (new) current track.
    private func trackDidChange(how: String) {
        endProgress()
        // The request is served
        if cursorRequested, store.playingIsActive, cursorTarget()?.pos == currentPos { cursorRequested = false }
        guard let pos = currentPos, let playlist = store.playingPlaylist,
              let track = track(at: pos, in: playlist) else { return }
        let album = playlist.albums[pos.album]

        store.setLastPlayed(track.id)
        fileInfoChecked = false
        info = TrackInfo(artist: track.artist, title: track.title, album: album.title,
                         year: album.year, codec: track.codec)
        position = 0
        duration = track.duration ?? 0
        loadArtworkIfNeeded(for: album, playing: pos.track)

        Log.info("playback: \(how): \(track.artist) – \(track.title) [\(album.title)], \(track.codec.isEmpty ? "format unknown" : track.codec), "
            + "playlist \"\(store.playingName ?? "")\", \(track.url.path)")
        let played = PlayedTrack(artist: track.artist, title: track.title, album: album.title,
                                 duration: track.duration ?? 0, startedAt: Date(), coverKey: album.key)
        progress = PlayProgress(track: played)
        for listener in listeners { listener.value?.trackDidStart(played) }
    }

    /// The current track is left (another one starts, or playback stops): the listener hears how far it got.
    /// Runs before `duration` is replaced, so it is still the one of the track that ends.
    private func endProgress() {
        guard let finished = progress else { return }
        progress = nil
        var track = finished.track
        if duration > 0 { track.duration = duration }
        Log.info("playback: left \(track.artist) – \(track.title), listened to \(Self.clock(finished.played)) of \(Self.clock(track.duration))")
        for listener in listeners { listener.value?.trackDidEnd(track, playedSeconds: finished.played) }
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
                         year: album.year, codec: track.codec)
        loadArtworkIfNeeded(for: album, playing: pos.track)
    }

    /// Loads the original art of the album, unless it is the one already loaded (or loading), which is the case
    /// for every track change within an album.
    private func loadArtworkIfNeeded(for album: Album, playing trackIndex: Int) {
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
