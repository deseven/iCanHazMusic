import Foundation
import Observation

/// What a search looks at. A plain value, so a search can run off the main actor with the options it was started with.
struct SearchOptions: Equatable, Sendable {
    /// Playlists are results, found by their whole name.
    var playlists = true
    /// Albums are results, and the album name is a field to search (for the album and for its tracks).
    var albums = true
    /// Words are also found by letters in order and with typos, not only as a part of the text.
    var fuzzy = true

    /// Albums and playlists are both off: tracks are the only kind of result.
    var tracksOnly: Bool { !playlists && !albums }
}

/// The settings of Preferences > Search (config `search.*`): the owner of the switches, which keeps them in the
/// config. `nil` for `configStore` (tests): defaults, nothing is persisted.
@MainActor
@Observable
final class SearchSettings {
    static let shared = SearchSettings(configStore: .shared)

    /// Find playlists by name. Persisted in the config.
    var byPlaylistName: Bool {
        didSet {
            guard byPlaylistName != oldValue else { return }
            configStore?.update { $0.search.byPlaylistName = byPlaylistName }
            Log.info("search by playlist name: \(byPlaylistName ? "on" : "off")")
        }
    }

    /// Find albums by name. Persisted in the config.
    var byAlbumName: Bool {
        didSet {
            guard byAlbumName != oldValue else { return }
            configStore?.update { $0.search.byAlbumName = byAlbumName }
            Log.info("search by album name: \(byAlbumName ? "on" : "off")")
        }
    }

    /// Fuzzy matching. Persisted in the config.
    var fuzzy: Bool {
        didSet {
            guard fuzzy != oldValue else { return }
            configStore?.update { $0.search.fuzzy = fuzzy }
            Log.info("fuzzy search: \(fuzzy ? "on" : "off")")
        }
    }

    /// Return adds to the queue and Shift-Return plays (else the other way round). Persisted in the config.
    var preferAddingToQueue: Bool {
        didSet {
            guard preferAddingToQueue != oldValue else { return }
            configStore?.update { $0.search.preferAddingToQueue = preferAddingToQueue }
            Log.info("search prefers adding to queue: \(preferAddingToQueue ? "on" : "off")")
        }
    }

    @ObservationIgnored private let configStore: ConfigStore?

    init(configStore: ConfigStore? = nil) {
        self.configStore = configStore
        let search = configStore?.config.search ?? AppConfig.Search()
        byPlaylistName = search.byPlaylistName
        byAlbumName = search.byAlbumName
        fuzzy = search.fuzzy
        preferAddingToQueue = search.preferAddingToQueue
    }

    var options: SearchOptions {
        SearchOptions(playlists: byPlaylistName, albums: byAlbumName, fuzzy: fuzzy)
    }
}
