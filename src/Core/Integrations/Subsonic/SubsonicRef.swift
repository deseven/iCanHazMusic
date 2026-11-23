// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Where a playlist track that lives on a Subsonic server is: the connection (by its ID, which never changes, so the
/// name of the connection can) and the ID of the song on the server.
///
/// Like a track of a CUE sheet it isn't a file: it has a pseudo path in the playlist, `subsonic/{connection id}:{song id}`
/// (a UUID has no colon, so the first one ends it; the song ID is whatever the server uses), and an object in the
/// playlist file with what else is known about it (`TrackEntry`). What the engine plays is `url`
/// (`subsonic://{connection id}/{song id}?ext=flac`), which `SubsonicDownloads` turns into a file for as long as it is needed.
struct SubsonicRef: Equatable, Hashable, Sendable {
    static let scheme = "subsonic"
    static let pathPrefix = "subsonic/"

    let connection: UUID
    let songID: String
    /// The extension of the file the server has (`flac`), which the downloaded copy needs to be opened; "" if unknown.
    var suffix: String
    /// The album on the server (the playlist groups the tracks of an album by it), nil if unknown.
    var albumID: String?
    /// What `getCoverArt` is asked for; nil if the song has no cover.
    var coverArt: String?

    init(connection: UUID, songID: String, suffix: String = "", albumID: String? = nil, coverArt: String? = nil) {
        self.connection = connection
        self.songID = songID
        self.suffix = suffix
        self.albumID = albumID
        self.coverArt = coverArt
    }

    // MARK: Pseudo path

    /// What the track is stored under in the playlist.
    var path: String { Self.path(connection: connection, songID: songID) }

    static func path(connection: UUID, songID: String) -> String {
        "\(pathPrefix)\(connection.uuidString.lowercased()):\(songID)"
    }

    /// The connection and the song if `path` is such a path.
    static func parse(path: String) -> (connection: UUID, songID: String)? {
        guard path.hasPrefix(pathPrefix), let colon = path.firstIndex(of: ":") else { return nil }
        let id = path[path.index(path.startIndex, offsetBy: pathPrefix.count)..<colon]
        let song = String(path[path.index(after: colon)...])
        guard let connection = UUID(uuidString: String(id)), !song.isEmpty else { return nil }
        return (connection, song)
    }

    static func isSubsonicPath(_ path: String) -> Bool {
        parse(path: path) != nil
    }

    // MARK: URLs

    /// What the engine is given to play.
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = connection.uuidString.lowercased()
        components.path = "/" + songID
        if !suffix.isEmpty { components.queryItems = [URLQueryItem(name: "ext", value: suffix)] }
        return components.url ?? URL(string: "\(Self.scheme)://invalid/")!
    }

    /// The song, the connection and the suffix of a URL made by `url` (nothing else of the ref is in it).
    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host, let connection = UUID(uuidString: host) else { return nil }
        let song = String(url.path.dropFirst())
        guard !song.isEmpty else { return nil }
        self.connection = connection
        songID = song
        suffix = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ext" }?.value ?? ""
        albumID = nil
        coverArt = nil
    }

    /// Stands for the directory of the tracks of one album (`Album.directory`): not a place that exists, it only has
    /// to tell albums apart (`AlbumKey`).
    var albumURL: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = connection.uuidString.lowercased()
        components.path = "/album/" + (albumID ?? songID)
        return components.url ?? URL(string: "\(Self.scheme)://invalid/")!
    }
}

extension URL {
    /// The Subsonic song this URL stands for, nil for anything else.
    var subsonicRef: SubsonicRef? { SubsonicRef(url: self) }
}
