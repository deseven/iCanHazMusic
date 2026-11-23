// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import iCanHazMusic

/// A Subsonic server that keeps playlists, behind `StubTransport`: answers `ping`, `getPlaylists`, `getPlaylist`,
/// `createPlaylist`, `updatePlaylist` and `deletePlaylist` like a real one (every change dates the playlist anew), and
/// remembers every request. A song `a1` is track 1 of the album `Album A` (`al-a`), so songs are easy to group.
final class SubsonicPlaylistServer: @unchecked Sendable {
    struct Playlist {
        var id: String
        var name: String
        var owner = "bob"
        var songs: [String]
        var changed = 1
        var readOnly = false
    }

    struct Request {
        let method: String
        let params: [(String, String)]
        let isPost: Bool
        let url: URL

        func values(_ name: String) -> [String] { params.filter { $0.0 == name }.map(\.1) }
        func value(_ name: String) -> String? { values(name).first }
    }

    private let lock = NSLock()
    private var lists: [Playlist]
    private var isDown = false
    private var postAllowed = true
    private var requested: [Request] = []
    private var nextNumber = 100

    init(_ playlists: [Playlist] = []) {
        lists = playlists
    }

    var transport: StubTransport {
        StubTransport { [self] request, _ in try answer(request) }
    }

    // MARK: Controls

    var playlists: [Playlist] { lock.withLock { lists } }
    var requests: [Request] { lock.withLock { requested } }

    func requests(_ method: String) -> [Request] { requests.filter { $0.method == method } }

    func setDown(_ down: Bool) { lock.withLock { isDown = down } }
    func setPostAllowed(_ allowed: Bool) { lock.withLock { postAllowed = allowed } }

    func playlist(_ id: String) -> Playlist? { playlists.first { $0.id == id } }

    /// Somebody else changes a playlist.
    func change(_ id: String, songs: [String]) {
        lock.withLock {
            guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
            lists[index].songs = songs
            lists[index].changed += 1
        }
    }

    func add(_ playlist: Playlist) { lock.withLock { lists.append(playlist) } }
    func remove(_ id: String) { lock.withLock { lists.removeAll { $0.id == id } } }

    // MARK: Answers

    private func answer(_ request: URLRequest) throws -> StubTransport.Answer {
        let (down, post) = lock.withLock { (isDown, postAllowed) }
        if down { throw URLError(.cannotConnectToHost) }
        let isPost = request.httpMethod == "POST"
        if isPost, !post { return (405, Data()) }
        guard let url = request.url else { return (400, Data()) }

        let method = url.deletingPathExtension().lastPathComponent
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let query = isPost ? body : (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
        let made = Request(method: method, params: Self.pairs(of: query), isPost: isPost, url: url)
        lock.withLock { requested.append(made) }

        return lock.withLock { respond(to: made) }
    }

    /// Called with the lock held.
    private func respond(to request: Request) -> StubTransport.Answer {
        switch request.method {
        case "getPlaylists":
            let items = lists.map { Self.json($0, entries: false) }.joined(separator: ",")
            return SubsonicAnswer.ok(#","playlists":{"playlist":[\#(items)]}"#)

        case "getPlaylist":
            guard let playlist = lists.first(where: { $0.id == request.value("id") }) else {
                return SubsonicAnswer.failed(code: 70, message: "Playlist not found")
            }
            return SubsonicAnswer.ok(#","playlist":\#(Self.json(playlist, entries: true))"#)

        case "createPlaylist":
            if let id = request.value("playlistId") {
                guard let index = lists.firstIndex(where: { $0.id == id }) else {
                    return SubsonicAnswer.failed(code: 70, message: "Playlist not found")
                }
                lists[index].songs = request.values("songId")
                lists[index].changed += 1
                return SubsonicAnswer.ok(#","playlist":\#(Self.json(lists[index], entries: true))"#)
            }
            nextNumber += 1
            let made = Playlist(id: "p\(nextNumber)", name: request.value("name") ?? "", songs: request.values("songId"))
            lists.append(made)
            return SubsonicAnswer.ok(#","playlist":\#(Self.json(made, entries: true))"#)

        case "updatePlaylist":
            guard let index = lists.firstIndex(where: { $0.id == request.value("playlistId") }) else {
                return SubsonicAnswer.failed(code: 70, message: "Playlist not found")
            }
            if let name = request.value("name") { lists[index].name = name }
            let remove = Set(request.values("songIndexToRemove").compactMap { Int($0) })
            lists[index].songs = lists[index].songs.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
            lists[index].songs += request.values("songIdToAdd")
            lists[index].changed += 1
            return SubsonicAnswer.ok()

        case "deletePlaylist":
            lists.removeAll { $0.id == request.value("id") }
            return SubsonicAnswer.ok()

        default:
            return SubsonicAnswer.ok()
        }
    }

    // MARK: JSON

    static func song(_ id: String) -> String {
        let letter = id.prefix(1)
        let number = Int(id.dropFirst()) ?? 1
        return #"{"id":"\#(id)","title":"\#(id.uppercased())","album":"Album \#(letter.uppercased())","albumId":"al-\#(letter)","artist":"Artist","track":\#(number),"suffix":"mp3","duration":100}"#
    }

    private static func json(_ playlist: Playlist, entries: Bool) -> String {
        var text = #"{"id":"\#(playlist.id)","name":"\#(playlist.name)","owner":"\#(playlist.owner)","songCount":\#(playlist.songs.count),"changed":"c\#(playlist.changed)","readonly":\#(playlist.readOnly)"#
        if entries { text += #","entry":[\#(playlist.songs.map(song).joined(separator: ","))]"# }
        return text + "}"
    }

    private static func pairs(of text: String) -> [(String, String)] {
        text.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]).removingPercentEncoding ?? "", String(parts[1]).removingPercentEncoding ?? "")
        }
    }
}

/// Stands in for `SubsonicDownloads` where a gone playlist's files are deleted.
final class RecordingFileRemover: SubsonicSongFileRemoving {
    private(set) var removed: [[SubsonicRef]] = []

    @discardableResult
    func removeFiles(ofSongs refs: [SubsonicRef]) -> Int {
        removed.append(refs)
        return refs.count
    }

    var songIDs: Set<String> { Set(removed.flatMap { $0.map(\.songID) }) }
}
