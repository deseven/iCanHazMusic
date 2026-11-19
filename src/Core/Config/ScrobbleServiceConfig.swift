// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One scrobbling service as it is kept in `config.json` (the `scrobbling` array of `AppConfig`).
///
/// The secret (the password, token or key of the account, whatever the service calls it) is plain text in memory
/// and obfuscated in the file (`Obfuscation`). Decoding is forgiving like everywhere in the config: what can't be
/// read falls back to a default, only an entry without a known `type` is dropped (`AppConfig` decodes the array
/// leniently).
struct ScrobbleServiceConfig: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case listenbrainz
        /// The legacy Audioscrobbler 1.2.1 protocol (Last.fm, Libre.fm, and many compatible servers).
        case audioscrobbler

        var id: String { rawValue }

        var title: String {
            switch self {
            case .audioscrobbler: "Audioscrobbler"
            case .listenbrainz: "ListenBrainz"
            }
        }

        /// What the secret is called for this protocol (services and apps call it differently).
        var secretTitle: String {
            switch self {
            case .audioscrobbler: "Password / Token / Key"
            case .listenbrainz: "Token / Key"
            }
        }

        /// Whether the protocol needs the name of the account (ListenBrainz knows it by the token).
        var usesUsername: Bool { self == .audioscrobbler }

        /// Servers people commonly use, to pick from when filling in the endpoint.
        var commonEndpoints: [CommonEndpoint] {
            switch self {
            case .audioscrobbler:
                [CommonEndpoint(name: "Last.fm", url: ScrobbleServiceConfig.lastFMEndpoint),
                 CommonEndpoint(name: "Libre.fm", url: "https://turtle.libre.fm")]
            case .listenbrainz:
                [CommonEndpoint(name: "ListenBrainz", url: "https://api.listenbrainz.org")]
            }
        }
    }

    /// Last.fm's server for the Audioscrobbler protocol.
    static let lastFMEndpoint = "https://post.audioscrobbler.com"

    struct CommonEndpoint: Equatable, Sendable {
        let name: String
        let url: String
    }

    var id: UUID
    /// What the user calls the service; only there to tell the services apart.
    var name: String
    var type: Kind
    /// The base URL of the server without a trailing slash (see `normalizedEndpoint`).
    var endpoint: String
    var username: String
    var secret: String
    /// Tell the service what is playing now, not only what has been played.
    var submitNowPlaying: Bool
    var enabled: Bool

    init(id: UUID = UUID(), name: String, type: Kind, endpoint: String, username: String = "", secret: String = "",
         submitNowPlaying: Bool = true, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.endpoint = endpoint
        self.username = username
        self.secret = secret
        self.submitNowPlaying = submitNowPlaying
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case endpoint
        case username
        case secret
        case submitNowPlaying = "submit_now_playing"
        case enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Without a type the entry can't be told what to do; the caller drops it.
        type = try c.decode(Kind.self, forKey: .type)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        endpoint = (try? c.decodeIfPresent(String.self, forKey: .endpoint)) ?? ""
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        let encodedSecret = (try? c.decodeIfPresent(String.self, forKey: .secret)) ?? ""
        secret = Obfuscation.deobfuscated(encodedSecret) ?? ""
        submitNowPlaying = (try? c.decodeIfPresent(Bool.self, forKey: .submitNowPlaying)) ?? true
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(username, forKey: .username)
        try c.encode(Obfuscation.obfuscated(secret), forKey: .secret)
        try c.encode(submitNowPlaying, forKey: .submitNowPlaying)
        try c.encode(enabled, forKey: .enabled)
    }

    /// What the entry is called in the log and in messages.
    var displayName: String { name.isEmpty ? type.title : name }

    /// The same settings, with the name and the username trimmed and the endpoint normalized if it can be. A token
    /// (the secret of the ListenBrainz API) is trimmed too (pasting one often brings a space or a line break along); a
    /// password is kept as typed.
    var normalized: ScrobbleServiceConfig {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == .listenbrainz { result.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines) }
        result.endpoint = Self.normalizedEndpoint(endpoint) ?? endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Whether `other` talks to the same server as the same account. A change of only the name or the now playing
    /// switch doesn't need a new connection.
    func hasSameConnection(as other: ScrobbleServiceConfig) -> Bool {
        type == other.type && endpoint == other.endpoint && username == other.username && secret == other.secret
    }

    /// `text` as an endpoint: an `http` or `https` URL with a host, no query and no fragment, trailing slashes
    /// removed. nil if it isn't one.
    static func normalizedEndpoint(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string
    }

    /// Why the settings can't be saved, nil if they can. The name has to be told apart from the `others`.
    func problem(among others: [ScrobbleServiceConfig]) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a name." }
        let sameName = { (other: ScrobbleServiceConfig) -> Bool in
            other.id != id && other.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if others.contains(where: sameName) {
            return "Another service already has this name."
        }
        if Self.normalizedEndpoint(endpoint) == nil { return "Enter the endpoint as an http:// or https:// URL." }
        if secret.isEmpty { return "Enter the \(type.secretTitle.lowercased())." }
        return nil
    }

    /// The order the services are listed in: by name, as a person would sort them.
    static func isOrderedBefore(_ a: ScrobbleServiceConfig, _ b: ScrobbleServiceConfig) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        if order != .orderedSame { return order == .orderedAscending }
        return a.id.uuidString < b.id.uuidString
    }
}
