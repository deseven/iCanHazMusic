// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What is known about a playlist of a Subsonic server: what its last `getPlaylists` said, and which version of it the
/// cached content is; and the app's own setting `autoDownload`. Kept in the index of the connection's playlists
/// (`RemotePlaylistIndex`).
struct RemotePlaylistInfo: Codable, Equatable, Sendable {
    /// The server's ID of the playlist.
    let id: String
    var name: String
    /// Who it belongs to, as the server says (nil if it doesn't).
    var owner: String?
    /// Somebody else's playlist: it can be played, not changed.
    var isForeign: Bool
    /// The server says it can't be changed (OpenSubsonic `readonly`: smart playlists and the like).
    var isReadOnly: Bool
    /// When it was changed on the server last (`changed`, the server's text); nil if the server doesn't say.
    var changed: String?
    var songCount: Int?
    /// The `changed` of the version on the server that the cached content is ("" if the server doesn't say). nil: the
    /// content has to be read from the server (it never was, or it was changed here and the server hasn't confirmed it yet).
    var synced: String?
    /// All of its songs are downloaded and kept, whatever the cache size of the connection (`SubsonicAutoDownloads`).
    /// The app's own, the server knows nothing of it.
    var autoDownload: Bool

    init(id: String, name: String, owner: String? = nil, isForeign: Bool = false, isReadOnly: Bool = false,
         changed: String? = nil, songCount: Int? = nil, synced: String? = nil, autoDownload: Bool = false) {
        self.id = id
        self.name = name
        self.owner = owner
        self.isForeign = isForeign
        self.isReadOnly = isReadOnly
        self.changed = changed
        self.songCount = songCount
        self.synced = synced
        self.autoDownload = autoDownload
    }

    /// The server lets the user change it (whether it can be reached is another matter).
    var isOwnEditable: Bool { !isForeign && !isReadOnly }

    /// The cached content is the version the server has, as far as the last listing tells.
    var isUpToDate: Bool { synced != nil && synced == (changed ?? "") }

    enum CodingKeys: String, CodingKey {
        case id, name, owner
        case isForeign = "foreign"
        case isReadOnly = "readonly"
        case changed
        case songCount = "song_count"
        case synced
        case autoDownload = "auto_download"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        isForeign = (try? c.decodeIfPresent(Bool.self, forKey: .isForeign)) ?? false
        isReadOnly = (try? c.decodeIfPresent(Bool.self, forKey: .isReadOnly)) ?? false
        changed = try? c.decodeIfPresent(String.self, forKey: .changed)
        songCount = try? c.decodeIfPresent(Int.self, forKey: .songCount)
        synced = try? c.decodeIfPresent(String.self, forKey: .synced)
        autoDownload = (try? c.decodeIfPresent(Bool.self, forKey: .autoDownload)) ?? false
    }

    /// The order the playlists of a connection are shown in: by name, then by ID (names needn't differ).
    static func isOrderedBefore(_ a: RemotePlaylistInfo, _ b: RemotePlaylistInfo) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
}

/// `.cache/subsonic/{connection id}/playlists/index.json`: the playlists of a connection as the app saw them last, so
/// they are there (and play from what was downloaded) before the server answers, or when it doesn't. The content of each
/// is a `PlaylistFile` next to it (`fileName(of:)`).
///
/// ```json
/// {"version": 1, "playlists": [{"id": "pl-1", "name": "Road", "owner": "bob", "changed": "2026-03-16T03:18:41Z",
///                               "song_count": 12, "synced": "2026-03-16T03:18:41Z", "auto_download": false}]}
/// ```
struct RemotePlaylistIndex: Codable {
    static let currentVersion = 1
    static let fileName = "index.json"

    var version = RemotePlaylistIndex.currentVersion
    var playlists: [RemotePlaylistInfo] = []

    init(playlists: [RemotePlaylistInfo]) {
        self.playlists = playlists
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        let entries = (try? c.decodeIfPresent([Lossy].self, forKey: .playlists)) ?? []
        playlists = entries.compactMap(\.value)
    }

    private struct Lossy: Decodable {
        let value: RemotePlaylistInfo?
        init(from decoder: Decoder) throws {
            value = try? RemotePlaylistInfo(from: decoder)
        }
    }

    /// The playlists in the index at `url`; none if there is no (usable) index.
    static func load(from url: URL) -> [RemotePlaylistInfo] {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(RemotePlaylistIndex.self, from: data),
              index.version <= currentVersion else { return [] }
        return index.playlists
    }

    static func data(of playlists: [RemotePlaylistInfo]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(RemotePlaylistIndex(playlists: playlists))
    }

    /// The name of the content file of a playlist: the same every time, whatever the server's ID has in it.
    static func fileName(of id: String) -> String {
        String(format: "%016llx.json", id.stableHash)
    }
}

/// What the store needs from whoever keeps the remote playlists in step with their servers (`SubsonicPlaylists`).
@MainActor
protocol RemotePlaylistEditing: AnyObject {
    /// Whether the playlist can be changed now: it is the user's, its server can be reached and its content is what the
    /// server has.
    func canEdit(_ id: PlaylistID) -> Bool
    /// The content was changed here (tracks removed or moved, the albums grouped): the server is to have it too.
    /// `baseline`: what `synced` of the playlist was before this change (the version of the server it was made from).
    func playlistWasEdited(_ id: PlaylistID, baseline: String?)
    /// The playlist became the one that is shown: a good time to look at the server.
    func playlistWasOpened(_ id: PlaylistID)
}

extension Playlist {
    /// The songs of a remote playlist in order (the IDs on the server; tracks that aren't a server's are left out).
    var songIDs: [String] {
        albums.flatMap { $0.tracks.compactMap { $0.subsonic?.songID } }
    }
}
