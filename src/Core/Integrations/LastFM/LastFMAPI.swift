// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// The application credentials Last.fm issued for the app. They are not part of the sources: `build.sh` writes
/// them from `.env` into the bundle's `Info.plist`, obfuscated (see `obfuscated`). Without them (a plain
/// `swift build`, a bundle made without `.env`) the integration is unavailable.
///
/// The obfuscation only keeps the values from being read at a glance (Finder, `plutil`, `strings`). The key is in
/// the sources and in the binary, so it is no protection against anyone who looks for it.
struct LastFMCredentials: Equatable, Sendable {
    let apiKey: String
    let secret: String

    static let apiKeyInfoKey = "ICHMLastFMAPIKey"
    static let secretInfoKey = "ICHMLastFMAPISecret"

    /// The XOR key of the plist values. `build.sh` reads it from this line, so keep the format (changing the key
    /// needs a rebuild of the bundle, nothing else).
    static let obfuscationKey = "22d7ece7b0c98fd1de7a120d6e218169"

    /// The credentials of the running bundle, if it has any.
    static let bundled = LastFMCredentials(infoDictionary: Bundle.main.infoDictionary)

    init(apiKey: String, secret: String) {
        self.apiKey = apiKey
        self.secret = secret
    }

    /// From the obfuscated values of an `Info.plist`; nil if either is missing or not valid.
    init?(infoDictionary: [String: Any]?) {
        guard let key = (infoDictionary?[Self.apiKeyInfoKey] as? String).flatMap(Self.deobfuscated),
              let secret = (infoDictionary?[Self.secretInfoKey] as? String).flatMap(Self.deobfuscated) else { return nil }
        self.init(apiKey: key, secret: secret)
    }

    /// `text` XOR-ed with `obfuscationKey` (repeated), as base64. `build.sh` does the same.
    static func obfuscated(_ text: String) -> String {
        Data(xor(Array(text.utf8))).base64EncodedString()
    }

    /// The reverse of `obfuscated`; nil for anything that isn't base64 of a non-empty UTF-8 text.
    static func deobfuscated(_ encoded: String) -> String? {
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else { return nil }
        return String(data: Data(xor(Array(data))), encoding: .utf8)
    }

    private static func xor(_ bytes: [UInt8]) -> [UInt8] {
        let key = Array(obfuscationKey.utf8)
        return bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] }
    }
}

/// A session Last.fm gave for an authorized token.
struct LastFMSession: Equatable, Sendable {
    let key: String
    let username: String
}

/// What Last.fm answered with an error (or what stands for one: a network failure, a 5xx).
///
/// Last.fm documents the error codes but not which of them are worth repeating the request for, so the
/// classification is ours (`kind(forCode:)`).
struct LastFMError: Error, Equatable, Sendable, CustomStringConvertible {
    enum Kind: Equatable, Sendable {
        /// Might work later: the service is down or busy, no connection, a garbled answer. Worth retrying.
        case temporary
        /// The session (or the app's key) is not accepted, and will not be: the connection is over.
        case authentication
        /// Last.fm refuses this one request (bad parameters, ...); sending it again changes nothing.
        case rejected
    }

    let kind: Kind
    /// Last.fm's error code, if it sent one.
    let code: Int?
    let message: String

    /// Last.fm: "The token has not been authorized" (the user didn't confirm yet).
    static let tokenNotAuthorizedCode = 14

    var description: String {
        code.map { "\(message) (error \($0))" } ?? message
    }

    static func kind(forCode code: Int) -> Kind {
        switch code {
        case 4, 9, 10, 17, 26: .authentication      // authentication failed, invalid session, invalid or suspended API key
        case 8, 11, 16, 29: .temporary              // operation failed, service offline/unavailable, rate limit
        default: .rejected
        }
    }
}

/// One Last.fm method call. The API key, the session key, the signature and the format are added when it is sent.
struct LastFMCall: Equatable, Sendable {
    let method: String
    let params: [String: String]

    static let updateNowPlayingMethod = "track.updateNowPlaying"
    static let scrobbleMethod = "track.scrobble"

    static func getToken() -> LastFMCall {
        LastFMCall(method: "auth.getToken", params: [:])
    }

    static func getSession(token: String) -> LastFMCall {
        LastFMCall(method: "auth.getSession", params: ["token": token])
    }

    static func updateNowPlaying(_ track: PlayedTrack) -> LastFMCall {
        LastFMCall(method: updateNowPlayingMethod, params: trackParams(track))
    }

    /// `timestamp` is when the track started playing (Unix time), which is what Last.fm wants.
    static func scrobble(_ track: PlayedTrack) -> LastFMCall {
        var params = trackParams(track)
        params["timestamp"] = String(Int(track.startedAt.timeIntervalSince1970))
        return LastFMCall(method: scrobbleMethod, params: params)
    }

    private static func trackParams(_ track: PlayedTrack) -> [String: String] {
        var params = ["artist": track.artist, "track": track.title]
        if !track.album.isEmpty { params["album"] = track.album }
        if track.duration >= 1 { params["duration"] = String(Int(track.duration.rounded())) }
        return params
    }
}

/// Everything that is pure about talking to Last.fm: URLs, signing, building requests, reading answers.
enum LastFMAPI {
    static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    /// A request that takes longer than this is given up on (and counts as a failed try).
    static let requestTimeout: TimeInterval = 30

    /// Where the user confirms that the app may use their account.
    static func authorizationURL(credentials: LastFMCredentials, token: String) -> URL {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: credentials.apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return components.url!
    }

    static func profileURL(username: String) -> URL? {
        guard let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://www.last.fm/user/" + encoded)
    }

    // MARK: Requests

    /// The `api_sig`: the parameters sorted by name, each as name + value, followed by the secret, MD5 of that.
    /// `format` (and `callback`) are not signed.
    static func signature(for params: [String: String], secret: String) -> String {
        var text = ""
        for (name, value) in params.sorted(by: { $0.key < $1.key }) where name != "format" && name != "callback" {
            text += name + value
        }
        text += secret
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A signed POST for `call`; `sessionKey` for the methods that act on an account.
    static func request(for call: LastFMCall, credentials: LastFMCredentials, sessionKey: String?) -> URLRequest {
        var params = call.params
        params["method"] = call.method
        params["api_key"] = credentials.apiKey
        if let sessionKey { params["sk"] = sessionKey }
        params["api_sig"] = signature(for: params, secret: credentials.secret)
        params["format"] = "json"

        var request = URLRequest(appURL: endpoint, timeout: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(params).utf8)
        return request
    }

    static func formEncoded(_ params: [String: String]) -> String {
        params.sorted(by: { $0.key < $1.key })
            .map { "\(percentEncoded($0.key))=\(percentEncoded($0.value))" }
            .joined(separator: "&")
    }

    /// Everything except the unreserved characters is escaped (`&`, `=`, `+` and so on must not leak through).
    private static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: Answers

    /// The body of a successful answer, or the error that the answer stands for. Last.fm reports failures as
    /// `{"error": code, "message": "..."}`, with a 4xx status (403 for a bad session, 400 for a bad signature).
    static func check(status: Int, body: Data) throws -> Data {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let code = (object["error"] as? NSNumber)?.intValue {
            let message = object["message"] as? String ?? "Last.fm error \(code)"
            throw LastFMError(kind: LastFMError.kind(forCode: code), code: code, message: message)
        }
        guard (200..<300).contains(status) else {
            throw LastFMError(kind: .temporary, code: nil, message: "HTTP \(status)")
        }
        return body
    }

    static func parseToken(_ body: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty else {
            throw LastFMError(kind: .temporary, code: nil, message: "unexpected answer to the token request")
        }
        return token
    }

    static func parseSession(_ body: Data) throws -> LastFMSession {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let session = object["session"] as? [String: Any],
              let key = session["key"] as? String, !key.isEmpty,
              let name = session["name"] as? String, !name.isEmpty else {
            throw LastFMError(kind: .temporary, code: nil, message: "unexpected answer to the session request")
        }
        return LastFMSession(key: key, username: name)
    }
}
