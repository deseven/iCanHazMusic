// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// What went wrong with a call to a Subsonic server. The kind says what to do about it.
struct SubsonicError: Error, Equatable, Sendable, CustomStringConvertible {
    enum Kind: Equatable, Sendable {
        /// The server can't be reached, or what answers isn't it (no network, a timeout, a 5xx from a proxy, an answer
        /// that isn't Subsonic's). The other endpoint of the connection may still work.
        case connection
        /// The username or password isn't accepted (or the user may not do this).
        case authentication
        /// The server doesn't have what was asked for (a song that was deleted or got a new ID).
        case notFound
        /// The server refuses this request.
        case rejected
    }

    let kind: Kind
    let message: String

    init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    var description: String { message }

    /// The server answered a POST with "not allowed" or "not implemented": the same can be asked with a GET.
    static let postNotAccepted = SubsonicError(.rejected, "the server doesn't take POST requests")
}

/// The `subsonic-response` object of an answer that said `ok`. The values are read through `SubsonicAPI.parse...`.
struct SubsonicResponse: @unchecked Sendable {
    let root: [String: Any]
}

struct SubsonicArtist: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let albumCount: Int?
}

struct SubsonicAlbum: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let artist: String
    let year: Int?
    let songCount: Int?
    /// What `getCoverArt` is asked for; nil if the album has no cover.
    let coverArt: String?
}

/// A playlist of the server (not its songs, see `SubsonicConnection.playlist`).
struct SubsonicPlaylist: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let songCount: Int?
    /// Seconds.
    let duration: TimeInterval?
    /// The user it belongs to, nil if the server doesn't say.
    var owner: String? = nil
    /// When it was changed last, as the server writes it (a date in ISO 8601, only compared for equality); nil if it doesn't say.
    var changed: String? = nil
    /// OpenSubsonic `readonly`: the user can't change it (smart playlists and the like).
    var isReadOnly = false

    /// Whether the user can change it: it is theirs (a server that doesn't name owners is taken at its word) and the
    /// server doesn't say otherwise.
    func isEditable(by username: String) -> Bool {
        if isReadOnly { return false }
        guard let owner else { return true }
        return owner.caseInsensitiveCompare(username) == .orderedSame
    }
}

struct SubsonicSong: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let album: String
    let albumID: String?
    let artist: String
    let track: Int?
    let disc: Int?
    let year: Int?
    /// Seconds.
    let duration: TimeInterval?
    /// The extension of the original file (`mp3`, `flac`), which is what `download` gives.
    let suffix: String?
    /// kbit/s, as the server says.
    let bitRate: Int?
    let coverArt: String?

    /// The order the songs of an album are in: by disc, then by track number (a song without a number goes last).
    static func isOrderedBefore(_ a: SubsonicSong, _ b: SubsonicSong) -> Bool {
        let (discA, discB) = (a.disc ?? 1, b.disc ?? 1)
        if discA != discB { return discA < discB }
        let (trackA, trackB) = (a.track ?? Int.max, b.track ?? Int.max)
        if trackA != trackB { return trackA < trackB }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}

/// Everything that is pure about the Subsonic API (also spoken by Navidrome and other compatible servers): building
/// the URLs and reading the answers. API version 1.16.1, JSON answers, token authentication.
///
/// - `GET {endpoint}/rest/{method}.view?u=...&t=md5(password + salt)&s=salt&v=1.16.1&c=iCanHazMusic&f=json&...`
/// - `ping`, `getArtists`, `getArtist`, `getAlbum`, `getSong`, `getPlaylists`, `getPlaylist`, `createPlaylist`,
///   `updatePlaylist`, `deletePlaylist`, `getCoverArt`, `download` and `scrobble` are used. What changes something
///   (the playlist methods that write) is sent as a POST with the parameters in the body.
///
/// The URLs carry the credentials (the token, which with its salt is good for any request), so they never go into
/// the log: see `redacted`.
enum SubsonicAPI {
    static let apiVersion = "1.16.1"
    static let clientName = AppConstants.appName

    // MARK: Requests

    /// `md5(password + salt)`, lower case hex.
    static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8)).hexString
    }

    /// A new random salt (16 hex digits); every request has its own.
    static func makeSalt() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// The URL of `method` at `endpoint` (a normalized endpoint, without a trailing slash).
    static func url(endpoint: String, method: String, username: String, password: String,
                    params: [(String, String)] = [], salt: String = makeSalt()) -> URL? {
        let pairs = authentication(username: username, password: password, salt: salt) + params
        return URL(string: "\(endpoint)/rest/\(method).view?\(FormEncoding.encode(pairs))")
    }

    /// The parameters every request has: who asks, the token and how the answer is wanted.
    static func authentication(username: String, password: String, salt: String = makeSalt()) -> [(String, String)] {
        [
            ("u", username),
            ("t", token(password: password, salt: salt)),
            ("s", salt),
            ("v", apiVersion),
            ("c", clientName),
            ("f", "json"),
        ]
    }

    /// The URL of `method` at `endpoint` without any parameters: what a POST goes to (they are in the body, see `formBody`).
    static func bareURL(endpoint: String, method: String) -> URL? {
        URL(string: "\(endpoint)/rest/\(method).view")
    }

    /// The body of a POST (`application/x-www-form-urlencoded`): the credentials and `params`. Used for what changes
    /// something on the server: a playlist with many songs would not fit in a URL, and the URL stays free of credentials.
    static func formBody(username: String, password: String, params: [(String, String)],
                         salt: String = makeSalt()) -> Data {
        Data(FormEncoding.encode(authentication(username: username, password: password, salt: salt) + params).utf8)
    }

    /// `url` without the query: what can be written into the log.
    static func redacted(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.string ?? url.host ?? "the server"
    }

    // MARK: Answers

    /// The `subsonic-response` of an answer, or the error it stands for.
    static func parse(status: Int, body: Data) throws -> SubsonicResponse {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let root = object["subsonic-response"] as? [String: Any] else {
            switch status {
            case 401, 403: throw SubsonicError(.authentication, "HTTP \(status)")
            case 0, 408, 429, 500...599: throw SubsonicError(.connection, "HTTP \(status)")
            default: throw SubsonicError(.connection, "the answer isn't from a Subsonic server (HTTP \(status))")
            }
        }
        if (root["status"] as? String) == "ok" { return SubsonicResponse(root: root) }

        let error = root["error"] as? [String: Any]
        let message = error?.string("message") ?? "the server reported an error"
        throw SubsonicError(kind(forCode: error?.int("code")), message)
    }

    /// The body of an answer to a method that sends a file (`getCoverArt`): the bytes, or the error that a server sends
    /// instead (as JSON, or XML for the ones that don't know `f=json`).
    static func parseFile(status: Int, body: Data) throws -> Data {
        let first = body.first(where: { !$0.isASCIIWhitespace })
        if status == 200, !body.isEmpty, first != UInt8(ascii: "{"), first != UInt8(ascii: "<") { return body }
        _ = try parse(status: status, body: body)
        throw SubsonicError(.rejected, "the server didn't send a file")
    }

    /// What a Subsonic error code (the ones in the API description) means for us.
    static func kind(forCode code: Int?) -> SubsonicError.Kind {
        switch code {
        case 40?, 41?, 42?, 43?, 44?, 50?: .authentication
        case 70?: .notFound
        default: .rejected
        }
    }

    /// "Navidrome 0.53.3 (API 1.16.1)" for the log and the test result.
    static func serverInfo(_ response: SubsonicResponse) -> String {
        let root = response.root
        let name = root.string("type").map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Subsonic"
        var text = name
        if let version = root.string("serverVersion") { text += " \(version)" }
        if let api = root.string("version") { text += " (API \(api))" }
        return text
    }

    static func parseArtists(_ response: SubsonicResponse) -> [SubsonicArtist] {
        let container = response.root["artists"] as? [String: Any]
        let indexes = container?.dictionaries("index") ?? []
        return indexes.flatMap { $0.dictionaries("artist") }.compactMap(artist(from:))
    }

    /// The artist and its albums.
    static func parseArtist(_ response: SubsonicResponse) -> (artist: SubsonicArtist, albums: [SubsonicAlbum])? {
        guard let object = response.root["artist"] as? [String: Any], let artist = artist(from: object) else { return nil }
        return (artist, object.dictionaries("album").compactMap { album(from: $0, artist: artist.name) })
    }

    /// The album and its songs (in the order the server has them).
    static func parseAlbum(_ response: SubsonicResponse) -> (album: SubsonicAlbum, songs: [SubsonicSong])? {
        guard let object = response.root["album"] as? [String: Any], let album = album(from: object, artist: "") else { return nil }
        let songs = object.dictionaries("song").compactMap { song(from: $0, album: album) }
        return (album, songs)
    }

    static func parsePlaylists(_ response: SubsonicResponse) -> [SubsonicPlaylist] {
        let container = response.root["playlists"] as? [String: Any]
        return (container?.dictionaries("playlist") ?? []).compactMap(playlist(from:))
    }

    /// The songs of the playlist, in its order (a song can be in it more than once).
    static func parsePlaylistEntries(_ response: SubsonicResponse) -> [SubsonicSong]? {
        guard let object = response.root["playlist"] as? [String: Any] else { return nil }
        return object.dictionaries("entry").filter { ($0["isDir"] as? Bool) != true }.compactMap { song(from: $0, album: nil) }
    }

    /// The playlist itself (what `getPlaylist`, `createPlaylist` and the like say about it, not its songs).
    static func parsePlaylist(_ response: SubsonicResponse) -> SubsonicPlaylist? {
        (response.root["playlist"] as? [String: Any]).flatMap(playlist(from:))
    }

    static func parseSong(_ response: SubsonicResponse) -> SubsonicSong? {
        guard let object = response.root["song"] as? [String: Any] else { return nil }
        return song(from: object, album: nil)
    }

    private static func artist(from object: [String: Any]) -> SubsonicArtist? {
        guard let id = object.string("id") else { return nil }
        return SubsonicArtist(id: id, name: object.string("name") ?? "", albumCount: object.int("albumCount"))
    }

    private static func playlist(from object: [String: Any]) -> SubsonicPlaylist? {
        guard let id = object.string("id") else { return nil }
        return SubsonicPlaylist(id: id, name: object.string("name") ?? "", songCount: object.int("songCount"),
                                duration: object.int("duration").map(TimeInterval.init),
                                owner: object.string("owner"), changed: object.string("changed"),
                                isReadOnly: (object["readonly"] as? Bool) ?? false)
    }

    private static func album(from object: [String: Any], artist fallbackArtist: String) -> SubsonicAlbum? {
        guard let id = object.string("id") else { return nil }
        return SubsonicAlbum(
            id: id,
            name: object.string("name") ?? object.string("title") ?? "",
            artist: object.string("artist") ?? fallbackArtist,
            year: object.int("year"),
            songCount: object.int("songCount"),
            coverArt: object.string("coverArt")
        )
    }

    private static func song(from object: [String: Any], album: SubsonicAlbum?) -> SubsonicSong? {
        guard let id = object.string("id") else { return nil }
        return SubsonicSong(
            id: id,
            title: object.string("title") ?? "",
            album: object.string("album") ?? album?.name ?? "",
            albumID: object.string("albumId") ?? album?.id,
            artist: object.string("artist") ?? "",
            track: object.int("track"),
            disc: object.int("discNumber"),
            year: object.int("year") ?? album?.year,
            duration: object.int("duration").map(TimeInterval.init),
            suffix: object.string("suffix")?.lowercased(),
            bitRate: object.int("bitRate"),
            coverArt: object.string("coverArt") ?? album?.coverArt
        )
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}

/// Servers differ in what they make a number or a string; these read both (an empty string is nothing).
private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let text = self[key] as? String { return text.isEmpty ? nil : text }
        if let number = self[key] as? NSNumber { return number.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let number = self[key] as? NSNumber { return number.intValue }
        if let text = self[key] as? String { return Int(text) }
        return nil
    }

    /// An array of objects; a single object counts as an array of one (some servers send it that way).
    func dictionaries(_ key: String) -> [[String: Any]] {
        if let list = self[key] as? [[String: Any]] { return list }
        if let one = self[key] as? [String: Any] { return [one] }
        return []
    }
}
