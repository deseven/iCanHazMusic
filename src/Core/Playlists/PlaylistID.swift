// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Which playlist: one of this Mac, known by its name (`playlists/{name}.json`), or one of a Subsonic server, known by the
/// connection and the server's ID for it. The name of a remote playlist is only a label (several can have the same one),
/// see `RemotePlaylistInfo`.
///
/// Saved as text (`config.json`: the active playlist, the playback state): a local playlist is its name, a remote one
/// `subsonic:{connection id}/{playlist id}`. A local name can't have a `:` or a `/` in it (`PlaylistStore.validate`),
/// so the two can't be mistaken for each other.
///
/// A string literal is a local playlist (`"main"`), which is what most code and the tests deal with.
enum PlaylistID: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    case local(String)
    case remote(connection: UUID, id: String)

    static let remotePrefix = "subsonic:"

    init(stringLiteral value: String) {
        self = .local(value)
    }

    /// Reads what `text` wrote; anything that isn't a remote playlist's text is a local name.
    init(text: String) {
        if text.hasPrefix(Self.remotePrefix) {
            let rest = text.dropFirst(Self.remotePrefix.count)
            if let slash = rest.firstIndex(of: "/"), let connection = UUID(uuidString: String(rest[..<slash])) {
                let id = String(rest[rest.index(after: slash)...])
                if !id.isEmpty {
                    self = .remote(connection: connection, id: id)
                    return
                }
            }
        }
        self = .local(text)
    }

    var text: String {
        switch self {
        case .local(let name): name
        case .remote(let connection, let id): "\(Self.remotePrefix)\(connection.uuidString.lowercased())/\(id)"
        }
    }

    var description: String { text }

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    /// The name of a local playlist.
    var localName: String? {
        if case .local(let name) = self { return name }
        return nil
    }

    /// The connection of a remote playlist.
    var connection: UUID? {
        if case .remote(let connection, _) = self { return connection }
        return nil
    }

    /// The server's ID of a remote playlist.
    var remoteID: String? {
        if case .remote(_, let id) = self { return id }
        return nil
    }
}
