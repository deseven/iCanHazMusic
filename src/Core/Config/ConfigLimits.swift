import Foundation

/// Limits for values stored in `config.json`. Values outside of them are reset to defaults.
/// The UI derives its sizing constants from these (see `Layout`), so both always agree.
enum ConfigLimits {
    // Window (content size, i.e. without the title bar)
    static let windowMinWidth = 800
    static let windowMinHeight = 600
    static let windowMaxSide = 20_000

    // Sidebar (playlist selector)
    static let sidebarMin = 120
    static let sidebarMax = 250

    // Playback block
    static let blockMinWidth = 270
    static let blockMaxWidth = 1200
}
