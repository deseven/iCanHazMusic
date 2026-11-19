// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// What a handshake gives: the session and where to send the now playing updates and the submissions to. Valid for
/// one run of the app, never stored.
struct AudioscrobblerSession: Equatable, Sendable {
    let id: String
    let nowPlayingURL: URL
    let submissionURL: URL
}

/// Everything that is pure about the Audioscrobbler 1.2.1 protocol (the legacy "Submissions Protocol" of Last.fm, also
/// spoken by Libre.fm and many compatible servers): building the requests and reading the answers.
///
/// 1. Handshake: `GET {endpoint}/?hs=true&p=1.2.1&c=..&v=..&u=..&t=..&a=..` answers `OK`, the session ID, the
///    now playing URL and the submission URL, one per line.
/// 2. Now playing: `POST` to the now playing URL.
/// 3. Submission: `POST` to the submission URL, one track at a time.
enum AudioscrobblerAPI {
    static let protocolVersion = "1.2.1"
    /// The client ID of the app. Last.fm doesn't hand out new ones for this protocol (and says that it may stop
    /// accepting the test one), the other servers take anything.
    static let clientID = "ich"

    // MARK: Requests

    /// `md5(md5(password) + timestamp)`, lower case hex.
    static func token(password: String, timestamp: Int) -> String {
        let inner = Insecure.MD5.hash(data: Data(password.utf8)).hexString
        return Insecure.MD5.hash(data: Data((inner + String(timestamp)).utf8)).hexString
    }

    /// The handshake. nil if `endpoint` doesn't make a URL.
    static func handshakeRequest(endpoint: String, username: String, password: String, timestamp: Int,
                                 clientVersion: String = AppConstants.appVersion) -> URLRequest? {
        let query = FormEncoding.encode([
            ("hs", "true"), ("p", protocolVersion), ("c", clientID), ("v", clientVersion),
            ("u", username), ("t", String(timestamp)), ("a", token(password: password, timestamp: timestamp)),
        ])
        guard let url = URL(string: endpoint + "/?" + query) else { return nil }
        return URLRequest(appURL: url, timeout: ScrobbleHTTP.requestTimeout)
    }

    static func nowPlayingRequest(_ track: PlayedTrack, session: AudioscrobblerSession) -> URLRequest {
        post(to: session.nowPlayingURL, [
            ("s", session.id), ("a", track.artist), ("t", track.title), ("b", track.album),
            ("l", length(of: track)), ("n", number(of: track)), ("m", ""),
        ])
    }

    /// One track in the request (index 0). Every field is there, empty if not known; the source is "chosen by the
    /// user" (`P`).
    static func submissionRequest(_ track: PlayedTrack, session: AudioscrobblerSession) -> URLRequest {
        post(to: session.submissionURL, [
            ("s", session.id), ("a[0]", track.artist), ("t[0]", track.title),
            ("i[0]", String(Int(track.startedAt.timeIntervalSince1970))), ("o[0]", "P"), ("r[0]", ""),
            ("l[0]", length(of: track)), ("b[0]", track.album), ("n[0]", number(of: track)), ("m[0]", ""),
        ])
    }

    private static func post(to url: URL, _ pairs: [(String, String)]) -> URLRequest {
        var request = URLRequest(appURL: url, timeout: ScrobbleHTTP.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(pairs).utf8)
        return request
    }

    private static func length(of track: PlayedTrack) -> String {
        track.duration >= 1 ? String(Int(track.duration.rounded())) : ""
    }

    private static func number(of track: PlayedTrack) -> String {
        track.trackNumber.map { $0 > 0 ? String($0) : "" } ?? ""
    }

    // MARK: Answers

    static func parseHandshake(status: Int, body: Data, retryAfter: TimeInterval? = nil) throws -> AudioscrobblerSession {
        guard status == 200 else { throw ScrobbleHTTP.error(forStatus: status, detail: bodyDetail(body), retryAfter: retryAfter) }
        let lines = lines(of: body)
        let first = lines.first ?? ""
        switch first {
        case "OK":
            guard lines.count >= 4, !lines[1].isEmpty,
                  let nowPlaying = httpURL(lines[2]), let submission = httpURL(lines[3]) else {
                throw ScrobbleError(.temporary, "the server's handshake answer is incomplete")
            }
            return AudioscrobblerSession(id: lines[1], nowPlayingURL: nowPlaying, submissionURL: submission)
        case "BADAUTH":
            throw ScrobbleError(.authentication, "the server doesn't accept the username and password (BADAUTH)")
        case "BANNED":
            throw ScrobbleError(.authentication, "the server has banned this client (BANNED)")
        case "BADTIME":
            throw ScrobbleError(.authentication, "the server doesn't accept the time of this computer, check its clock (BADTIME)")
        default:
            throw unexpected(first, body)
        }
    }

    enum Reply: Equatable {
        case ok
        /// The session isn't valid (any more): a new handshake is needed.
        case badSession
    }

    /// The answer to a now playing update or a submission.
    static func parseReply(status: Int, body: Data, retryAfter: TimeInterval? = nil) throws -> Reply {
        guard status == 200 else { throw ScrobbleHTTP.error(forStatus: status, detail: bodyDetail(body), retryAfter: retryAfter) }
        let first = lines(of: body).first ?? ""
        switch first {
        case "OK": return .ok
        case "BADSESSION": return .badSession
        default: throw unexpected(first, body)
        }
    }

    private static func unexpected(_ first: String, _ body: Data) -> ScrobbleError {
        if first.hasPrefix("FAILED") {
            let reason = first.dropFirst("FAILED".count).trimmingCharacters(in: .whitespaces)
            return ScrobbleError(.temporary, reason.isEmpty ? "the server failed (FAILED)" : "the server failed: \(reason) (FAILED)")
        }
        return ScrobbleError(.temporary, "unexpected answer from the server: \(ScrobbleHTTP.snippet(of: body))")
    }

    /// The text of an error answer, if it has any worth showing (not a page of HTML).
    private static func bodyDetail(_ body: Data) -> String? {
        let text = ScrobbleHTTP.snippet(of: body, limit: 80)
        return text.isEmpty || text.hasPrefix("<") ? nil : text
    }

    private static func lines(of body: Data) -> [String] {
        String(decoding: body, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func httpURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}
