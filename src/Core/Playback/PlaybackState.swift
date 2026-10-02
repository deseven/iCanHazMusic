import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// The playback engine and everything the playback block shows.
///
/// Gapless playback comes from an `AVQueuePlayer` that always holds at most two items: the current track and
/// the one after it in the playlist (the next album's first track after the last track of an album). The next
/// one is enqueued as soon as a track starts, so AVFoundation has time to prepare it. Whenever the user changes
/// what's playing (a new track, next/previous, ...) the queue is emptied and built again.
///
/// Playback runs from a playlist held by `PlaylistStore` (`playingPlaylist`), which stays in memory while
/// something is playing or paused, even if another playlist is being browsed. The state is purely transitional:
/// it knows the position `(album, track)` in that playlist and a copy of what to display, nothing is persisted.
@MainActor
@Observable
final class PlaybackState {
    static let shared = PlaybackState()

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
        didSet { player.volume = Float(volume) }
    }

    var isStopped: Bool { status == .stopped }

    // MARK: Internals

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private let store = PlaylistStore.shared

    @ObservationIgnored private var currentPos: Position?
    @ObservationIgnored private var nextPos: Position?
    @ObservationIgnored private var currentItem: AVPlayerItem?
    @ObservationIgnored private var nextItem: AVPlayerItem?
    @ObservationIgnored private var statusObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var currentItemObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?

    /// `Album.key` of the album the loaded (or loading) artwork belongs to.
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    @ObservationIgnored private var seekToken = 0
    @ObservationIgnored private var isSeeking = false

    private init() {
        player.volume = Float(volume)

        // KVO fires on whatever thread AVFoundation uses, so always hop to the main actor and look at the
        // player's state there.
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemDidChange() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
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
            player.pause()
            status = .paused
        case .paused:
            player.play()
            status = .playing
        case .stopped:
            break
        }
    }

    func stop() {
        status = .stopped
        player.pause()
        clearQueue()
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = nil
        artwork = nil
        info = nil
        position = 0
        duration = 0
        isSeeking = false
        store.playbackEnded()
    }

    /// Does nothing on the last track of the playlist.
    func nextTrack() {
        syncWithPlayer()
        guard let pos = currentPos, let next = following(pos) else { return }
        begin(at: next)
    }

    /// The previous track, or the beginning of the current one if it is the first.
    func previousTrack() {
        syncWithPlayer()
        guard let pos = currentPos else { return }
        begin(at: preceding(pos) ?? pos)
    }

    /// Does nothing in the last album of the playlist.
    func nextAlbum() {
        syncWithPlayer()
        guard let pos = currentPos, let playlist = store.playingPlaylist,
              pos.album + 1 < playlist.albums.count else { return }
        begin(at: Position(album: pos.album + 1, track: 0))
    }

    /// The first track of the previous album (of the current one if it is the first).
    func previousAlbum() {
        syncWithPlayer()
        guard let pos = currentPos else { return }
        begin(at: Position(album: max(pos.album - 1, 0), track: 0))
    }

    func seek(to seconds: Double) {
        guard status != .stopped, duration > 0 else { return }
        let target = min(max(seconds, 0), max(duration - 0.05, 0))
        position = target

        isSeeking = true
        seekToken += 1
        let token = seekToken
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekToken == token else { return }
                self.isSeeking = false
            }
        }
    }

    /// The playing playlist got more tracks (they are only ever added at the end, which keeps the position
    /// valid). The track after the current one may be a different one now, or exist at all if the current one
    /// was the last.
    func playlistDidChange() {
        guard status != .stopped else { return }
        syncWithPlayer()
        guard let pos = currentPos, following(pos) != nextPos else { return }
        removeNext()
        prepareNext(after: pos)
    }

    // MARK: - Queue management

    /// Replaces the queue with `pos` and the track after it, and plays.
    private func begin(at pos: Position) {
        guard let playlist = store.playingPlaylist, let track = track(at: pos, in: playlist) else {
            stop()
            return
        }

        player.pause()
        clearQueue()

        let item = makeItem(for: track.url)
        currentItem = item
        currentPos = pos
        player.insert(item, after: nil)
        prepareNext(after: pos)

        status = .playing
        isSeeking = false
        trackDidChange()
        player.play()
    }

    /// Enqueues the track following `pos`, if there is one.
    private func prepareNext(after pos: Position) {
        guard let playlist = store.playingPlaylist, let next = following(pos),
              let track = track(at: next, in: playlist) else {
            nextPos = nil
            nextItem = nil
            return
        }
        let item = makeItem(for: track.url)
        nextPos = next
        nextItem = item
        player.insert(item, after: nil)
    }

    private func removeNext() {
        if let item = nextItem {
            statusObservers[ObjectIdentifier(item)] = nil
            player.remove(item)
        }
        nextItem = nil
        nextPos = nil
    }

    private func clearQueue() {
        player.removeAllItems()
        statusObservers.removeAll()
        currentItem = nil
        nextItem = nil
        currentPos = nil
        nextPos = nil
    }

    private func makeItem(for url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        statusObservers[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.itemDidFail(item) }
        }
        return item
    }

    // MARK: - Reacting to the player

    private func currentItemDidChange() {
        syncWithPlayer()
    }

    /// Brings our idea of the current track in line with the player's: the queue moves on by itself at the
    /// end of a track, which is the gapless transition.
    private func syncWithPlayer() {
        guard status != .stopped else { return }
        let item = player.currentItem
        if let item, item === currentItem { return }

        if let item, item === nextItem, let pos = nextPos {
            if let old = currentItem { statusObservers[ObjectIdentifier(old)] = nil }
            currentItem = item
            currentPos = pos
            nextItem = nil
            nextPos = nil
            trackDidChange()
            prepareNext(after: pos)
        } else {
            // The queue ran out: the end of the playlist, or (very short tracks) it was refilled too late.
            let last = nextPos ?? currentPos
            if let last, let next = following(last) {
                begin(at: next)
            } else {
                stop()
            }
        }
    }

    private func itemDidFail(_ item: AVPlayerItem) {
        guard status != .stopped else { return }
        let name = (item.asset as? AVURLAsset)?.url.lastPathComponent ?? "?"
        Log.error("can't play \(name): \(item.error?.localizedDescription ?? "unknown error")")

        if item === currentItem, let pos = currentPos {
            if let next = following(pos) { begin(at: next) } else { stop() }
        } else if item === nextItem, let failed = nextPos {
            removeNext()
            prepareNext(after: failed)
        }
    }

    private func tick() {
        guard status != .stopped, let item = player.currentItem else { return }

        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0, abs(seconds - duration) > 0.01 { duration = seconds }

        guard !isSeeking else { return }
        let time = player.currentTime().seconds
        if time.isFinite, time >= 0, abs(time - position) > 0.01 { position = time }
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
