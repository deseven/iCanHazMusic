// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Everything that is pure about the ListenBrainz API (also spoken by compatible servers): building the requests and
/// reading the answers. The user is told by the token in the `Authorization` header.
///
/// - `GET {endpoint}/1/validate-token`
/// - `POST {endpoint}/1/submit-listens` with a `playing_now` listen (now playing) or a `single` one (a scrobble)
/// - `POST {endpoint}/1/playing-now/delete` to clear the now playing status when playback stops (a listen
///   isn't always cleared by the server on its own, it expires only after the duration of the track)
enum ListenBrainzAPI {
    static func validateRequest(endpoint: String, token: String) -> URLRequest? {
        request(endpoint: endpoint, path: "/1/validate-token", token: token)
    }

    static func nowPlayingRequest(_ track: PlayedTrack, endpoint: String, token: String) -> URLRequest? {
        submitRequest(listenType: "playing_now", track: track, listenedAt: nil, endpoint: endpoint, token: token)
    }

    static func scrobbleRequest(_ track: PlayedTrack, endpoint: String, token: String) -> URLRequest? {
        submitRequest(listenType: "single", track: track, listenedAt: track.startedAt, endpoint: endpoint, token: token)
    }

    /// Clears the now playing status unconditionally (an empty body: no `client` to match it against).
    static func clearNowPlayingRequest(endpoint: String, token: String) -> URLRequest? {
        guard var request = request(endpoint: endpoint, path: "/1/playing-now/delete", token: token) else { return nil }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        return request
    }

    /// Like `check`, but a 404 is fine: there was nothing to clear (or the server doesn't have the endpoint, which
    /// compatible servers may not).
    static func checkClear(status: Int, body: Data, retryAfter: TimeInterval? = nil) throws {
        if status == 404 { return }
        try check(status: status, body: body, retryAfter: retryAfter)
    }

    private static func submitRequest(listenType: String, track: PlayedTrack, listenedAt: Date?,
                                      endpoint: String, token: String) -> URLRequest? {
        guard var request = request(endpoint: endpoint, path: "/1/submit-listens", token: token) else { return nil }
        var listen: [String: Any] = ["track_metadata": metadata(of: track)]
        if let listenedAt { listen["listened_at"] = Int(listenedAt.timeIntervalSince1970) }
        let body: [String: Any] = ["listen_type": listenType, "payload": [listen]]
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private static func request(endpoint: String, path: String, token: String) -> URLRequest? {
        guard let url = URL(string: endpoint + path) else { return nil }
        var request = URLRequest(appURL: url, timeout: ScrobbleHTTP.requestTimeout)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func metadata(of track: PlayedTrack) -> [String: Any] {
        var info: [String: Any] = [
            "media_player": AppConstants.appName,
            "media_player_version": AppConstants.appVersion,
            "submission_client": AppConstants.appName,
            "submission_client_version": AppConstants.appVersion,
        ]
        if track.duration >= 1 { info["duration"] = Int(track.duration.rounded()) }
        if let number = track.trackNumber, number > 0 { info["tracknumber"] = number }
        var result: [String: Any] = ["artist_name": track.artist, "track_name": track.title, "additional_info": info]
        if !track.album.isEmpty { result["release_name"] = track.album }
        return result
    }

    // MARK: Answers

    /// What the server says about the token: the name of the account it belongs to (nil if the server doesn't
    /// say), or the error.
    static func parseValidation(status: Int, body: Data, retryAfter: TimeInterval? = nil) throws -> String? {
        if status == 200 {
            guard let object = json(body), let valid = object["valid"] as? Bool else {
                throw ScrobbleError(.temporary, "unexpected answer from the server: \(ScrobbleHTTP.snippet(of: body))")
            }
            guard valid else { throw ScrobbleError(.authentication, "the server doesn't accept the user token") }
            return (object["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        try check(status: status, body: body, retryAfter: retryAfter)
        return nil
    }

    /// Succeeds for an accepted listen, throws what the answer stands for otherwise (`retryAfter`: what the server
    /// asked for with the answer, goes with a temporary error).
    static func check(status: Int, body: Data, retryAfter: TimeInterval? = nil) throws {
        if (200..<300).contains(status) { return }
        let detail = message(in: body)
        switch status {
        case 401, 403:
            throw ScrobbleError(.authentication, "the server doesn't accept the user token (\(detail ?? "HTTP \(status)"))")
        case 400:
            throw ScrobbleError(.rejected, "the server refused the request: \(detail ?? "HTTP 400")")
        default:
            throw ScrobbleHTTP.error(forStatus: status, detail: detail, retryAfter: retryAfter)
        }
    }

    private static func message(in body: Data) -> String? {
        if let object = json(body), let text = (object["error"] ?? object["message"]) as? String, !text.isEmpty {
            return text
        }
        let text = ScrobbleHTTP.snippet(of: body, limit: 80)
        return text.isEmpty || text.hasPrefix("<") ? nil : text
    }

    private static func json(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}
