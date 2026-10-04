import Foundation
import Observation

/// Lyrics of what plays, and of any track on request.
///
/// - The source of truth are the lyrics in the tags of the file: they are put into the `LyricsStore` when the tags
///   are read (`ImportSession`).
/// - When a track starts its lyrics are taken from the store (`current`). If there are none and LRCLIB is turned on
///   (`isLRCLIBEnabled`, config `integrations.lrclib.enabled`, off by default), LRCLIB is asked once, through an
///   `LRCLIBQueue` (in the background, with retries); lyrics it has for exactly this artist and title are stored,
///   and shown as soon as they are there. A "no" is remembered until the app quits, so replaying a track doesn't ask
///   again; a lookup that failed is tried again the next time the track starts.
/// - Tracks without tags (`PlayedTrack.hasTags`) are never looked up.
@MainActor
@Observable
final class LyricsService: PlaybackListener {
    static let shared = LyricsService(configStore: .shared, store: .shared)

    /// Ask LRCLIB for the lyrics of tracks that have none. Persisted in the config.
    var isLRCLIBEnabled: Bool {
        didSet {
            guard isLRCLIBEnabled != oldValue else { return }
            configStore.update { $0.integrations.lrclib.enabled = isLRCLIBEnabled }
            Log.info("lrclib: \(isLRCLIBEnabled ? "on" : "off")")
            if isLRCLIBEnabled {
                if let playing, current == nil { lookUpOnLRCLIB(playing) }
            } else {
                queue?.cancelAll()
                pending.removeAll()
            }
        }
    }

    /// The lyrics of the track that plays (or is paused), nil if there are none (yet).
    private(set) var current: Lyrics?
    /// `LyricsKey` of the track that plays, nil while nothing does or the track has no tags.
    private(set) var currentKey: String?
    /// Counts changes of the store that may add lyrics to tracks (LRCLIB found some, tags were read again); `hasLyrics`
    /// reads it, so views that call that are redrawn when it changes.
    private(set) var revision = 0

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let store: LyricsStore
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let spacing: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var queue: LRCLIBQueue?
    @ObservationIgnored private var playing: PlayedTrack?
    /// Keys that are in the queue.
    @ObservationIgnored private var pending = Set<String>()
    /// Keys LRCLIB has no lyrics for.
    @ObservationIgnored private var unavailable = Set<String>()

    init(configStore: ConfigStore, store: LyricsStore,
         transport: any HTTPTransport = URLSessionTransport(timeout: LRCLIBAPI.requestTimeout),
         spacing: Duration = .milliseconds(300),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.configStore = configStore
        self.store = store
        self.transport = transport
        self.spacing = spacing
        self.sleep = sleep
        isLRCLIBEnabled = configStore.config.integrations.lrclib.enabled
    }

    // MARK: - Any track

    /// The stored lyrics of a track; nil if there are none, or the track has no tags.
    func lyrics(artist: String, title: String, album: String) -> Lyrics? {
        guard TagFallback.isIdentified(artist: artist, title: title) else { return nil }
        return store.lyrics(for: LyricsKey.make(artist: artist, title: title, album: album))
    }

    func hasLyrics(artist: String, title: String, album: String) -> Bool {
        _ = revision
        guard TagFallback.isIdentified(artist: artist, title: title) else { return false }
        return store.contains(LyricsKey.make(artist: artist, title: title, album: album))
    }

    /// The store changed under the playing track (its tags were read again): look again.
    func refreshCurrent() {
        revision += 1
        guard let currentKey else { return }
        current = store.lyrics(for: currentKey)
    }

    // MARK: - Playback

    func trackDidStart(_ track: PlayedTrack) {
        playing = track
        guard track.hasTags else {
            current = nil
            currentKey = nil
            return
        }
        let key = LyricsKey.make(artist: track.artist, title: track.title, album: track.album)
        currentKey = key
        current = store.lyrics(for: key)
        if current == nil { lookUpOnLRCLIB(track) }
    }

    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval) {
        guard playing?.startedAt == track.startedAt else { return }
        playing = nil
        current = nil
        currentKey = nil
    }

    // MARK: - LRCLIB

    private func lookUpOnLRCLIB(_ track: PlayedTrack) {
        let key = LyricsKey.make(artist: track.artist, title: track.title, album: track.album)
        guard isLRCLIBEnabled, track.hasTags, !unavailable.contains(key), pending.insert(key).inserted else { return }
        let queue = self.queue ?? makeQueue()
        queue.enqueue(LRCLIBQuery(artist: track.artist, title: track.title, album: track.album, duration: track.duration))
    }

    private func makeQueue() -> LRCLIBQueue {
        let queue = LRCLIBQueue(client: LRCLIBClient(transport: transport), spacing: spacing, sleep: sleep) { [weak self] query, outcome in
            self?.didFinish(query, outcome)
        }
        self.queue = queue
        return queue
    }

    private func didFinish(_ query: LRCLIBQuery, _ outcome: LRCLIBOutcome) {
        let key = LyricsKey.make(artist: query.artist, title: query.title, album: query.album)
        pending.remove(key)
        switch outcome {
        case .found(let lyrics):
            // The file's own lyrics may have turned up while the request was on its way: they win.
            if store.store(lyrics, for: key, replacing: false) { revision += 1 }
            if key == currentKey { current = store.lyrics(for: key) ?? lyrics }
        case .notFound:
            unavailable.insert(key)
        case .failed:
            break
        }
    }
}
