// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CryptoKit
import ImageIO

/// The big covers of Subsonic albums (what the Now Playing block shows and the playlist's thumbnails are made from), kept on
/// disk so that they are there when the server isn't, and aren't asked for again and again (see `SubsonicCovers`).
///
/// - One file per album in `{connection id}/covers/`, named `{hash of the album}.{hash of the cover id and size}`. The
///   second part says which picture it is: servers put a version into the cover ids (Navidrome adds the time of the last
///   change), so a changed cover is a new id. A file of the album with another cover id is *stale*: worth replacing when
///   the server answers, better than nothing when it doesn't.
/// - Never pruned (a cover is a few hundred KB) and independent of the connection's cache size, which is about the
///   downloaded songs; deleted with the connection's directory (`SubsonicDownloads.removeCache`).
/// - Blocking file access: call it off the main thread.
final class SubsonicCoverCache: Sendable {
    /// What `lookup` found.
    struct Hit: Equatable {
        let data: Data
        /// Made for the very cover id that was asked for; otherwise a picture the album had before.
        let isCurrent: Bool
    }

    /// `directory`: the one that has a directory per connection (`AppPaths.subsonicCacheDir`).
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The cover of `album` (the server's ID of it, or the cover id for a song without one). nil if there is none.
    func lookup(connection: UUID, album: String, art: String, size: Int?) -> Hit? {
        let name = Self.fileName(album: album, art: art, size: size)
        let folder = coversDirectory(of: connection)
        if let data = Self.read(folder.appendingPathComponent(name, isDirectory: false)) {
            return Hit(data: data, isCurrent: true)
        }
        let prefix = Self.albumPrefix(album)
        for file in Self.children(of: folder) where file.lastPathComponent.hasPrefix(prefix) {
            if let data = Self.read(file) { return Hit(data: data, isCurrent: false) }
        }
        return nil
    }

    /// Keeps `data` as the cover of `album`, in place of what the album had before. Something that isn't an image is not kept.
    func store(_ data: Data, connection: UUID, album: String, art: String, size: Int?) {
        guard Self.isImage(data) else { return }
        let folder = coversDirectory(of: connection)
        let name = Self.fileName(album: album, art: art, size: size)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name, isDirectory: false), options: .atomic)
        } catch {
            Log.error("subsonic: a cover could not be saved: \(error.localizedDescription)")
            return
        }
        let prefix = Self.albumPrefix(album)
        for file in Self.children(of: folder) where file.lastPathComponent.hasPrefix(prefix) && file.lastPathComponent != name {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func coversDirectory(of connection: UUID) -> URL {
        AppPaths.subsonicDir(of: connection, in: directory).appendingPathComponent(AppPaths.subsonicCoversDirName, isDirectory: true)
    }

    // MARK: - Names

    /// The start of the name of every file of an album, whatever the cover.
    static func albumPrefix(_ album: String) -> String {
        SHA256.hash(data: Data(album.utf8)).prefix(16).hexString + "."
    }

    static func fileName(album: String, art: String, size: Int?) -> String {
        albumPrefix(album) + SHA256.hash(data: Data("\(art)|\(size ?? 0)".utf8)).prefix(8).hexString
    }

    // MARK: - Files

    private static func read(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return data
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    private static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
