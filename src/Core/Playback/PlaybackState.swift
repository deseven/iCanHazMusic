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
/// Playback runs from a playlist held by `PlaylistStore` (`playingPlaylist`), which stays in memory while
/// something is playing or paused, even if another playlist is being browsed. The state is purely transitional:
/// it knows the position `(album, track)` in that playlist and a copy of what to display, nothing is persisted.
@MainActor
@Observable
final class PlaybackState {
    static let shared = PlaybackState(store: .shared, engine: PlaybackEngine(), configStore: .shared)

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

    /// A track to play: in the playing playlist, or (`foreign`) in the active one when that is another playlist
    /// (the user moved the cursor there, see `playbackFollowsCursor`). Playback only switches to that playlist when
    /// the track starts.
    private struct Target: Equatable {
        var pos: Position
        var foreign = false
    }

    private(set) var status: Status = .stopped
    private(set) var info: TrackInfo?
    /// Seconds into the current track.
    private(set) var position: Double = 0
    /// Seconds. 0 while stopped or unknown.
    private(set) var duration: Double = 0
    /// Original album art cut to a square. The only one kept in memory; nil while loading or if there is none.
    private(set) var artwork: CGImage?

    var volume: Double = 0.7 {
        didSet { engine.volume = Float(volume) }
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

    // MARK: Internals

    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private let store: PlaylistStore
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private let positionStep: Double
    @ObservationIgnored private let configStore: ConfigStore?

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
    /// `configStore`: where `cursorFollowsPlayback` and `playbackFollowsCursor` are read from and kept; `nil` uses
    /// the defaults and persists nothing.
    init(store: PlaylistStore, engine: PlaybackEngine, tickInterval: Duration? = .milliseconds(250),
         positionStep: Double = 1, configStore: ConfigStore? = nil) {
        self.store = store
        self.engine = engine
        self.tickInterval = tickInterval
        self.positionStep = positionStep
        self.configStore = configStore
        if let settings = configStore?.config.playback {
            cursorFollowsPlayback = settings.cursorFollowsPlayback
            playbackFollowsCursor = settings.playbackFollowsCursor
        }
        engine.volume = Float(volume)
        engine.onEvent = { [weak self] event in self?.handle(event) }
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
        begin(at: Position(album: albumIndex, track: trackIndex))
    }

    /// Starts playing the track of a row of the active playlist; an album header starts its first track.
    func play(row id: Int) {
        guard !store.isLoading else { return }
        let rows = store.activePlaylist.rows
        guard rows.indices.contains(id) else { return }
        play(albumIndex: rows[id].albumIndex, trackIndex: rows[id].trackIndex ?? 0)
    }

    func togglePause() {
        switch status {
        case .playing:
            engine.pause()
            status = .paused
        case .paused:
            engine.resume()
            status = .playing
        case .stopped:
            break
        }
    }

    func stop() {
        status = .stopped
        engine.stop()
        stopTicking()
        currentPos = nil
        nextPos = nil
        cursorRequested = false
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = nil
        artwork = nil
        info = nil
        position = 0
        duration = 0
        store.playbackEnded()
    }

    /// Does nothing on the last track of the playlist.
    func nextTrack() {
        syncWithEngine()
        guard let pos = currentPos, let next = nextTarget(after: pos) else { return }
        begin(at: next.pos, foreign: next.foreign)
    }

    /// The previous track, or the beginning of the current one if it is the first.
    func previousTrack() {
        syncWithEngine()
        guard let pos = currentPos else { return }
        begin(at: preceding(pos) ?? pos)
    }

    /// Does nothing in the last album of the playlist.
    func nextAlbum() {
        syncWithEngine()
        guard let pos = currentPos, let playlist = store.playingPlaylist,
              pos.album + 1 < playlist.albums.count else { return }
        begin(at: Position(album: pos.album + 1, track: 0))
    }

    /// The first track of the previous album (of the current one if it is the first).
    func previousAlbum() {
        syncWithEngine()
        guard let pos = currentPos else { return }
        begin(at: Position(album: max(pos.album - 1, 0), track: 0))
    }

    func seek(to seconds: Double) {
        guard status != .stopped, duration > 0 else { return }
        let target = min(max(seconds, 0), max(duration - 0.05, 0))
        position = target
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
            stop()
            return
        }

        currentPos = moved
        nextPos = nil
        refreshInfo()
        prepareNext(after: moved)
    }

    // MARK: - Queue management

    /// Replaces the engine's queue with `pos` and the track after it, and plays. `foreign`: `pos` is in the active
    /// playlist, which is not the playing one; playback moves over to it.
    private func begin(at pos: Position, foreign: Bool = false) {
        if foreign {
            guard !store.isLoading, track(at: pos, in: store.activePlaylist) != nil else {
                stop()
                return
            }
            store.playbackStarted()
        }
        guard let playlist = store.playingPlaylist, let track = track(at: pos, in: playlist) else {
            stop()
            return
        }

        currentPos = pos
        nextPos = nextTarget(after: pos)
        nextURL = nextPos.flatMap { self.track(at: $0.pos, in: self.playlist(of: $0)) }?.url
        engine.start(track.url, next: nextURL)

        status = .playing
        trackDidChange()
        startTicking()
    }

    /// Hands the track following `pos` (if there is one) to the engine.
    private func prepareNext(after pos: Position) {
        guard let next = nextTarget(after: pos), let track = track(at: next.pos, in: playlist(of: next)) else {
            nextPos = nil
            nextURL = nil
            engine.setNext(nil)
            return
        }
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
            // The queue ran out: the end of the playlist, or (very short tracks) it was refilled too late.
            if let queued = nextPos, queued.foreign {
                begin(at: queued.pos, foreign: true)
            } else if let last = nextPos?.pos ?? currentPos, let next = nextTarget(after: last) {
                begin(at: next.pos, foreign: next.foreign)
            } else {
                stop()
            }
        case .failed(let url, let wasCurrent, _):
            if wasCurrent, let pos = currentPos {
                if let next = nextTarget(after: pos) { begin(at: next.pos, foreign: next.foreign) } else { stop() }
            } else if let failed = nextPos, track(at: failed.pos, in: playlist(of: failed))?.url == url {
                if failed.foreign {
                    cursorRequested = false   // the track asked for can't be played: back to the playing playlist
                    if let pos = currentPos { prepareNext(after: pos) }
                } else {
                    prepareNext(after: failed.pos)
                }
            }
        case .deviceError:
            stop()
        }
    }

    /// The engine moved on by itself at the end of a track, which is the gapless transition.
    private func advanceToNext() {
        guard let next = nextPos else { return }
        if next.foreign {
            // The track the cursor asked for in another playlist starts: playback moves over to that playlist.
            // (If the shown playlist changed since, what plays isn't what it was meant to be: stop.)
            guard !store.isLoading, track(at: next.pos, in: store.activePlaylist)?.url == nextURL else {
                stop()
                return
            }
            store.playbackStarted()
        }
        currentPos = next.pos
        nextPos = nil
        trackDidChange()
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
    private func trackDidChange() {
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
        artworkTask?.cancel()

        let directory = album.directory
        let others = album.tracks.indices.lazy.filter { $0 != trackIndex }.prefix(2).map { album.tracks[$0].url }
        let files = [album.tracks[trackIndex].url] + others

        artworkTask = Task { [weak self] in
            let image = await PlaybackArtwork.load(directory: directory, embeddedFrom: files)
            guard !Task.isCancelled, let self, self.artworkKey == key else { return }
            self.artwork = image
        }
    }

    // MARK: - Playlist navigation

    private func track(at pos: Position, in playlist: Playlist?) -> Track? {
        guard let playlist, playlist.albums.indices.contains(pos.album),
              playlist.albums[pos.album].tracks.indices.contains(pos.track) else { return nil }
        return playlist.albums[pos.album].tracks[pos.track]
    }

    /// The track that plays after `pos`: the one the user moved the cursor to if `playbackFollowsCursor` is on
    /// (an album header stands for its first track), otherwise `following(pos)`.
    private func nextTarget(after pos: Position) -> Target? {
        if playbackFollowsCursor, cursorRequested, let target = cursorTarget(), target.foreign || target.pos != pos {
            return target
        }
        return following(pos).map { Target(pos: $0) }
    }

    /// The playlist a target is in.
    private func playlist(of target: Target) -> Playlist? {
        if target.foreign { return store.isLoading ? nil : store.activePlaylist }
        return store.playingPlaylist
    }

    /// `cursorRow` as a track of the active playlist (`foreign` if playback runs from another one).
    private func cursorTarget() -> Target? {
        guard status != .stopped, let row = cursorRow, !store.isLoading else { return nil }
        let rows = store.activePlaylist.rows
        guard rows.indices.contains(row) else { return nil }
        return Target(pos: Position(album: rows[row].albumIndex, track: rows[row].trackIndex ?? 0),
                      foreign: !store.playingIsActive)
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
