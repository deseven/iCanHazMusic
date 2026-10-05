// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What is asked of LRCLIB: the lyrics of one track.
struct LRCLIBQuery: Equatable, Sendable {
    let artist: String
    let title: String
    let album: String
    /// Seconds; 0 if unknown.
    let duration: TimeInterval
}

/// What went wrong with a request to LRCLIB (or what stands for it: no connection, a 5xx, a garbled answer).
struct LRCLIBError: Error, Equatable, Sendable, CustomStringConvertible {
    enum Kind: Equatable, Sendable {
        /// Might work later: the service is down or busy (429), no connection, a garbled answer. Worth retrying.
        case temporary
        /// LRCLIB refuses this request (a 4xx); sending it again changes nothing.
        case rejected
    }

    let kind: Kind
    let message: String
    /// How long LRCLIB asked to wait (`Retry-After` of a 429), seconds.
    var retryAfter: TimeInterval?

    var description: String { message }
}

/// Everything that is pure about talking to LRCLIB (https://lrclib.net/docs): requests, reading answers, choosing
/// the record that is the track asked for.
enum LRCLIBAPI {
    static let endpoint = URL(string: "https://lrclib.net/api/search")!
    /// A request that takes longer than this is given up on (and counts as a failed try).
    static let requestTimeout: TimeInterval = 30
    /// How far the duration of a record may be from the one of the track, as a share of the latter. (`/api/get`
    /// only takes 2 seconds, which is why the search is used.)
    static let durationTolerance = 0.1

    /// A GET that searches by artist and title. The album isn't part of it: the same song is on many albums, and
    /// whichever record fits best is picked from the (up to 20) answers.
    static func request(for query: LRCLIBQuery) -> URLRequest {
        let parameters = [("track_name", query.title), ("artist_name", query.artist)]
            .map { "\($0.0)=\(percentEncoded($0.1))" }
            .joined(separator: "&")
        var request = URLRequest(appURL: URL(string: endpoint.absoluteString + "?" + parameters)!, timeout: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Everything except the unreserved characters is escaped (`&`, `+`, `=` and so on mean something in a query).
    private static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: Answers

    /// The body of a successful answer, or the error the answer stands for. 429 comes with how long to wait.
    static func check(_ answer: HTTPAnswer) throws -> Data {
        switch answer.status {
        case 200..<300:
            return answer.body
        case 429:
            throw LRCLIBError(kind: .temporary, message: "HTTP 429 (too many requests)", retryAfter: answer.retryAfter)
        case 400..<500:
            throw LRCLIBError(kind: .rejected, message: "HTTP \(answer.status)\(message(in: answer.body).map { ": " + $0 } ?? "")")
        default:
            throw LRCLIBError(kind: .temporary, message: "HTTP \(answer.status)")
        }
    }

    private static func message(in body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["message"] as? String
    }

    /// The lyrics of the record of the answer that is the track asked for, nil if none is.
    ///
    /// A record is the track if artist and title are the same (case and blank space don't matter, nothing else) and
    /// its duration is within `durationTolerance` of the track's (not checked if the track's is unknown), and it has
    /// lyrics at all (instrumentals don't). Of those, synchronised lyrics win, then the record on the same album,
    /// then the nearest duration.
    static func match(for query: LRCLIBQuery, in body: Data) throws -> Lyrics? {
        guard let records = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            throw LRCLIBError(kind: .temporary, message: "unexpected answer to the search")
        }
        let artist = comparable(query.artist)
        let title = comparable(query.title)
        let album = comparable(query.album)

        var best: (lyrics: Lyrics, rank: [Double])?
        for record in records {
            guard let recordArtist = record["artistName"] as? String, comparable(recordArtist) == artist,
                  let recordTitle = record["trackName"] as? String, comparable(recordTitle) == title else { continue }
            let duration = (record["duration"] as? NSNumber)?.doubleValue
            if query.duration > 0 {
                guard let duration, abs(duration - query.duration) <= query.duration * durationTolerance else { continue }
            }
            let synced = (record["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard record["instrumental"] as? Bool != true,
                  let lyrics = Lyrics(source: .lrclib, plain: record["plainLyrics"] as? String, lrc: synced) else { continue }

            let sameAlbum = (record["albumName"] as? String).map { comparable($0) == album } ?? false
            let rank = [lyrics.isSynced ? 0 : 1, sameAlbum ? 0 : 1, abs((duration ?? query.duration) - query.duration)]
            if best == nil || rank.lexicographicallyPrecedes(best!.rank) { best = (lyrics, rank) }
        }
        return best?.lyrics
    }

    /// Case-insensitive, with the blank space inside and around collapsed.
    private static func comparable(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
