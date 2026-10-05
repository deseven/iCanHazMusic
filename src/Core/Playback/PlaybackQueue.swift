import Foundation
import Observation

/// A queued track: the playlist it is in and its ID there (see `TrackID`). Positions aren't used because they
/// don't survive an edit of the playlist; the queue only ever refers to tracks by this.
struct QueueEntry: Hashable, Sendable {
    let playlist: String
    let id: TrackID
}

/// The tracks that play next, one after the other, before playback goes on in the playlist (see `PlaybackState`).
/// Runtime only: nothing of it is stored.
///
/// A track can be in the queue once. The track that is playing never is: an entry leaves the queue when its track
/// starts (`started`). While the queue is turned off (`isEnabled`, "Enable Queue", config `general.queue_enabled`)
/// it can't be added to and is empty. `stopAtEnd` ("Stop at queue end", config `playback.stop_at_queue_end`) is only
/// kept here; playback acts on it.
///
/// `onChange` runs after the content has been changed by anything but `started`; playback uses it to hand the engine
/// the right track to play after the current one.
@MainActor
@Observable
final class PlaybackQueue {
    /// Persisted in the config. Turning the queue off empties it.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            configStore?.update { $0.general.queueEnabled = isEnabled }
            Log.info("queue: \(isEnabled ? "on" : "off")")
            if !isEnabled { clear() }
        }
    }

    /// Persisted in the config.
    var stopAtEnd: Bool {
        didSet {
            guard stopAtEnd != oldValue else { return }
            configStore?.update { $0.playback.stopAtQueueEnd = stopAtEnd }
            Log.info("stop at queue end: \(stopAtEnd ? "on" : "off")")
            onChange?()
        }
    }

    /// In playing order.
    private(set) var entries: [QueueEntry] = [] {
        didSet { positions = Dictionary(entries.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { first, _ in first }) }
    }

    /// Where each entry is (1 = plays next). Observed, so views that show a track's place in the queue follow it.
    private var positions: [QueueEntry: Int] = [:]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let configStore: ConfigStore?

    /// `configStore`: where the two settings are read from and kept; `nil` (tests) uses the defaults and persists nothing.
    init(configStore: ConfigStore? = nil) {
        self.configStore = configStore
        isEnabled = configStore?.config.general.queueEnabled ?? AppConfig.General().queueEnabled
        stopAtEnd = configStore?.config.playback.stopAtQueueEnd ?? AppConfig.Playback().stopAtQueueEnd
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func contains(_ entry: QueueEntry) -> Bool {
        positions[entry] != nil
    }

    /// 1 for the entry that plays next; `nil` if it isn't queued.
    func position(of entry: QueueEntry) -> Int? {
        positions[entry]
    }

    // MARK: Changing it

    /// Appends the entries that aren't queued yet, in the order given. Returns how many were added; none if the
    /// queue is off.
    @discardableResult
    func append(_ new: [QueueEntry]) -> Int {
        guard isEnabled else { return 0 }
        var seen = Set(entries)
        let fresh = new.filter { seen.insert($0).inserted }
        guard !fresh.isEmpty else { return 0 }
        entries += fresh
        Log.info("queue: added \(fresh.count), \(entries.count) queued")
        onChange?()
        return fresh.count
    }

    func remove(_ removed: Set<QueueEntry>) {
        let kept = entries.filter { !removed.contains($0) }
        guard kept.count != entries.count else { return }
        let count = entries.count - kept.count
        entries = kept
        Log.info("queue: removed \(count), \(entries.count) queued")
        onChange?()
    }

    /// `notify: false`: for playback itself, which is about to start something else and sorts out what plays next.
    func clear(because reason: String? = nil, notify: Bool = true) {
        guard !entries.isEmpty else { return }
        entries = []
        Log.info("queue: cleared" + (reason.map { " (\($0))" } ?? ""))
        if notify { onChange?() }
    }

    /// Takes the entry out because its track starts now. Returns whether it was queued. Doesn't call `onChange`:
    /// playback is in the middle of starting that track.
    @discardableResult
    func started(_ entry: QueueEntry) -> Bool {
        guard contains(entry) else { return false }
        entries.removeAll { $0 == entry }
        return true
    }

    // MARK: Playlists changing

    /// Tracks were removed from a playlist.
    func remove(ids: Set<TrackID>, fromPlaylist name: String) {
        remove(Set(entries.filter { $0.playlist == name && ids.contains($0.id) }))
    }

    /// A playlist was deleted.
    func removeAll(inPlaylist name: String) {
        remove(Set(entries.filter { $0.playlist == name }))
    }

    /// A playlist got another name; its entries keep their places.
    func renamePlaylist(from old: String, to new: String) {
        guard old != new, entries.contains(where: { $0.playlist == old }) else { return }
        entries = entries.map { $0.playlist == old ? QueueEntry(playlist: new, id: $0.id) : $0 }
        onChange?()
    }
}
