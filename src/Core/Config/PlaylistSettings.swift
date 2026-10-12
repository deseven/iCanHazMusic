// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// How the album blocks (headers) of playlists grouped by albums look (`playlist.album_header_style` in the config;
/// the raw value is what the file holds).
enum AlbumHeaderStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The album art on the left, then three lines: artist, album, tags.
    case albumArt = "album_art"
    /// Mirrored: the three lines aligned to the right, the album art at the right edge.
    case albumArtRight = "album_art_right"
    /// One line: the artist on the left, the tags and the album on the right. No album art is shown or loaded (it is
    /// still cached when adding files).
    case noAlbumArt = "no_album_art"

    static let `default`: AlbumHeaderStyle = .albumArt

    var id: String { rawValue }

    var showsArt: Bool { self != .noAlbumArt }

    var title: String {
        switch self {
        case .albumArt: "With Album Art"
        case .albumArtRight: "With Album Art (Right)"
        case .noAlbumArt: "No Album Art"
        }
    }
}

/// How playlists look (Preferences > Playlist, config `playlist.*`): the style of the album blocks, the size of the
/// track rows and their columns in each `PlaylistMode`. The owner of those settings, which keeps them in the config.
/// `nil` for `configStore` (tests): defaults, nothing is persisted.
@MainActor
@Observable
final class PlaylistSettings {
    static let shared = PlaylistSettings(configStore: .shared)

    /// Persisted in the config.
    var albumHeaderStyle: AlbumHeaderStyle {
        didSet {
            guard albumHeaderStyle != oldValue else { return }
            configStore?.update { $0.playlist.albumHeaderStyle = albumHeaderStyle }
            Log.info("album header style: \(albumHeaderStyle.rawValue)")
        }
    }

    /// Size of the track rows in percent (`ConfigLimits.playlistEntriesScaleMin...Max`). Persisted in the config.
    /// Not logged: a slider drags through it.
    var entriesScale: Int {
        didSet {
            guard entriesScale != oldValue else { return }
            configStore?.update { $0.playlist.entriesScale = entriesScale }
        }
    }

    /// The columns of playlists grouped by albums. Persisted in the config.
    var albumColumns: PlaylistColumnsLayout {
        didSet {
            guard albumColumns != oldValue else { return }
            configStore?.update { $0.playlist.albumColumns = albumColumns }
            Log.info("playlist columns (album mode): \(albumColumns.summary)")
        }
    }

    /// The columns of flat playlists. Persisted in the config.
    var flatColumns: PlaylistColumnsLayout {
        didSet {
            guard flatColumns != oldValue else { return }
            configStore?.update { $0.playlist.flatColumns = flatColumns }
            Log.info("playlist columns (flat mode): \(flatColumns.summary)")
        }
    }

    @ObservationIgnored private let configStore: ConfigStore?

    init(configStore: ConfigStore? = nil) {
        self.configStore = configStore
        let playlist = configStore?.config.playlist ?? AppConfig.Playlist()
        albumHeaderStyle = playlist.albumHeaderStyle
        entriesScale = playlist.entriesScale
        albumColumns = playlist.albumColumns
        flatColumns = playlist.flatColumns
    }

    /// The columns of `mode`, to read or change.
    subscript(columns mode: PlaylistMode) -> PlaylistColumnsLayout {
        get {
            switch mode {
            case .album: albumColumns
            case .flat: flatColumns
            }
        }
        set {
            switch mode {
            case .album: albumColumns = newValue
            case .flat: flatColumns = newValue
            }
        }
    }

    func resetColumns(_ mode: PlaylistMode) {
        self[columns: mode] = .default(mode)
    }
}
