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
    static let shared = PlaybackState(store: .shared, engine: PlaybackEngine())

    enum Status { case stopped, playing, paused }

    /// What the playback block shows about the current track.
    struct TrackInfo {
        let artist: String
        let title: String
        let album: String
        let year: String?
        let codec: String
    }

    private struct Position: Equatable {
        var album: Int
        var track: Int
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

    var isStopped: Bool { status == .stopped }

    // MARK: Internals

    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private let store: PlaylistStore
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private let positionStep: Double

    @ObservationIgnored private var currentPos: Position?
    @ObservationIgnored private var nextPos: Position?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    /// `Album.key` of the album the loaded (or loading) artwork belongs to.
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    /// `tickInterval`: how often the position is refreshed while something plays; `nil` leaves that to `tick()`.
    /// `positionStep`: `position` is only published when it moves into another multiple of this many seconds
    /// (the UI shows whole seconds, and every change re-renders the views reading it, which costs ~1.5% CPU at
    /// 4 updates a second); 0 publishes every change.
    init(store: PlaylistStore, engine: PlaybackEngine, tickInterval: Duration? = .milliseconds(250),
         positionStep: Double = 1) {
        self.store = store
        self.engine = engine
        self.tickInterval = tickInterval
        self.positionStep = positionStep
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
        guard let pos = currentPos, let next = following(pos) else { return }
        begin(at: next)
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

    /// The playing playlist got more tracks (they are only ever added at the end, which keeps the position
    /// valid). The track after the current one may be a different one now, or exist at all if the current one
    /// was the last.
    func playlistDidChange() {
        guard status != .stopped else { return }
        syncWithEngine()
        guard let pos = currentPos, following(pos) != nextPos else { return }
        prepareNext(after: pos)
    }

    // MARK: - Queue management

    /// Replaces the engine's queue with `pos` and the track after it, and plays.
    private func begin(at pos: Position) {
        guard let playlist = store.playingPlaylist, let track = track(at: pos, in: playlist) else {
            stop()
            return
        }

        currentPos = pos
        nextPos = following(pos)
        let next = nextPos.flatMap { self.track(at: $0, in: playlist) }
        engine.start(track.url, next: next?.url)

        status = .playing
        trackDidChange()
        startTicking()
    }

    /// Hands the track following `pos` (if there is one) to the engine.
    private func prepareNext(after pos: Position) {
        guard let playlist = store.playingPlaylist, let next = following(pos),
              let track = track(at: next, in: playlist) else {
            nextPos = nil
            engine.setNext(nil)
            return
        }
        nextPos = next
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
            if let last = nextPos ?? currentPos, let next = following(last) {
                begin(at: next)
            } else {
                stop()
            }
        case .failed(let url, let wasCurrent, _):
            if wasCurrent, let pos = currentPos {
                if let next = following(pos) { begin(at: next) } else { stop() }
            } else if let failed = nextPos, let playlist = store.playingPlaylist,
                      track(at: failed, in: playlist)?.url == url {
                prepareNext(after: failed)
            }
        case .deviceError:
            stop()
        }
    }

    /// The engine moved on by itself at the end of a track, which is the gapless transition.
    private func advanceToNext() {
        guard let pos = nextPos else { return }
        currentPos = pos
        nextPos = nil
        trackDidChange()
        prepareNext(after: pos)
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
        let time = engine.position
        guard time.isFinite, time >= 0 else { return }
        let moved = positionStep > 0
            ? (time / positionStep).rounded(.down) != (position / positionStep).rounded(.down)
            : abs(time - position) > 0.01
        if moved { position = time }
    }

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
        guard let pos = currentPos, let playlist = store.playingPlaylist,
              let track = track(at: pos, in: playlist) else { return }
        let album = playlist.albums[pos.album]

        info = TrackInfo(artist: track.artist, title: track.title, album: album.title,
                         year: album.year, codec: track.codec)
        position = 0
        duration = track.duration ?? 0
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

    private func track(at pos: Position, in playlist: Playlist) -> Track? {
        guard playlist.albums.indices.contains(pos.album),
              playlist.albums[pos.album].tracks.indices.contains(pos.track) else { return nil }
        return playlist.albums[pos.album].tracks[pos.track]
    }

    /// The track that plays after `pos`: the next one of the album, else the first of the next album.
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
