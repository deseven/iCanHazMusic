import Foundation

/// What a custom hotkey can do. The raw value is the key of the hotkey in `config.json` (`hotkeys.<rawValue>`).
enum HotkeyAction: String, CaseIterable, Identifiable {
    case playPause = "play_pause"
    case nextTrack = "next_track"
    case previousTrack = "previous_track"
    case nextAlbum = "next_album"
    case previousAlbum = "previous_album"
    case randomTrack = "random_track"
    case randomAlbum = "random_album"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: "Play/Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .nextAlbum: "Next Album"
        case .previousAlbum: "Previous Album"
        case .randomTrack: "Random Track"
        case .randomAlbum: "Random Album"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        }
    }
}
