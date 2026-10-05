import Foundation

/// Which track follows the current one (`playback.order` in the config; the raw value is what the file holds).
enum PlaybackOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The playlist order: the next track of the album, then the first track of the next album.
    case standard = "default"
    /// A random track, never the one that just played (unless it is the only one). Indefinite.
    case trackShuffle = "track_shuffle"
    /// The tracks of the album in their order, then the first track of a random other album. Indefinite.
    case albumShuffle = "album_shuffle"

    static let `default`: PlaybackOrder = .standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Default"
        case .trackShuffle: "Track shuffle"
        case .albumShuffle: "Album shuffle"
        }
    }

    var isShuffle: Bool { self != .standard }
}

/// What happens when nothing follows the last track (`playback.at_playlist_end` in the config). With a shuffle
/// order there is always something to follow, except when the playlist has nothing else to pick (one track, or
/// one album for album shuffle).
enum PlaylistEnd: String, Codable, CaseIterable, Identifiable, Sendable {
    case stop
    /// Continues with the first track of the playlist (a shuffle order picks again).
    case startOver = "start_over"

    static let `default`: PlaylistEnd = .stop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stop: "Stop"
        case .startOver: "Start over"
        }
    }
}
