// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One Subsonic (or Navidrome, or any other compatible) server as it is kept in `config.json` (the `subsonic` array of
/// `AppConfig`).
///
/// - `id` is what tracks refer to the server by (`SubsonicPath`); it never changes, so the name is only for people and
///   can be edited any time.
/// - The server can have two addresses: `localEndpoint` (at home) and `publicEndpoint` (anywhere else). At least one
///   has to be set; `SubsonicConnection` decides which is used.
/// - The password is plain text in memory and obfuscated in the file (`Obfuscation`): token authentication needs
///   the password itself, so it can't be kept hashed.
///
/// Decoding is forgiving like everywhere in the config: what can't be read falls back to a default.
struct SubsonicConnectionConfig: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// What the user calls the server; shown in the UI and the log, nothing refers to it.
    var name: String
    /// The address that works from anywhere; "" if there is none. See `normalizedEndpoint`.
    var publicEndpoint: String
    /// The address that works only in the local network (and is preferred while it answers); "" if there is none.
    var localEndpoint: String
    var username: String
    var password: String
    /// Tell the server what was listened to (its play count, and whatever it forwards to, e.g. Last.fm).
    var sendScrobbles: Bool
    var enabled: Bool
    /// How much of the downloaded songs of this server is kept on disk (see `SubsonicDownloads`).
    var cacheSize: SubsonicCacheSize

    init(id: UUID = UUID(), name: String = "", publicEndpoint: String = "", localEndpoint: String = "",
         username: String = "", password: String = "", sendScrobbles: Bool = false, enabled: Bool = true,
         cacheSize: SubsonicCacheSize = .default) {
        self.id = id
        self.name = name
        self.publicEndpoint = publicEndpoint
        self.localEndpoint = localEndpoint
        self.username = username
        self.password = password
        self.sendScrobbles = sendScrobbles
        self.enabled = enabled
        self.cacheSize = cacheSize
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case publicEndpoint = "public_endpoint"
        case localEndpoint = "local_endpoint"
        case username
        case password
        case sendScrobbles = "send_scrobbles"
        case enabled
        case cacheSize = "cache_size"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        publicEndpoint = (try? c.decodeIfPresent(String.self, forKey: .publicEndpoint)) ?? ""
        localEndpoint = (try? c.decodeIfPresent(String.self, forKey: .localEndpoint)) ?? ""
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        let encodedPassword = (try? c.decodeIfPresent(String.self, forKey: .password)) ?? ""
        password = Obfuscation.deobfuscated(encodedPassword) ?? ""
        sendScrobbles = (try? c.decodeIfPresent(Bool.self, forKey: .sendScrobbles)) ?? false
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        let storedCacheSize = (try? c.decodeIfPresent(Int.self, forKey: .cacheSize)) ?? nil
        cacheSize = storedCacheSize.flatMap(SubsonicCacheSize.init(storedValue:)) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(publicEndpoint, forKey: .publicEndpoint)
        try c.encode(localEndpoint, forKey: .localEndpoint)
        try c.encode(username, forKey: .username)
        try c.encode(Obfuscation.obfuscated(password), forKey: .password)
        try c.encode(sendScrobbles, forKey: .sendScrobbles)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(cacheSize.storedValue, forKey: .cacheSize)
    }

    /// What the server is called in messages and the log.
    var displayName: String { name.isEmpty ? "Subsonic" : name }

    /// The address of one of the two kinds, as a URL, nil if it isn't set (or isn't an address).
    func endpoint(_ route: SubsonicRoute) -> String? {
        let text = route == .local ? localEndpoint : publicEndpoint
        return Self.normalizedEndpoint(text)
    }

    /// The addresses that are set, local first.
    var routes: [SubsonicRoute] {
        SubsonicRoute.allCases.filter { endpoint($0) != nil }
    }

    /// The same settings, tidied: the name and the username trimmed, the endpoints normalized if they can be. The
    /// password is kept as typed.
    var normalized: SubsonicConnectionConfig {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.publicEndpoint = Self.normalizedEndpoint(publicEndpoint) ?? publicEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        result.localEndpoint = Self.normalizedEndpoint(localEndpoint) ?? localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Whether `other` is the same server and account, reached the same ways. A change of only the name or the
    /// scrobbling switch doesn't need a new connection.
    func hasSameConnection(as other: SubsonicConnectionConfig) -> Bool {
        publicEndpoint == other.publicEndpoint && localEndpoint == other.localEndpoint
            && username == other.username && password == other.password
    }

    /// `text` as an endpoint: an `http` or `https` URL with a host, no query and no fragment, no trailing slashes, and
    /// no trailing `/rest` (people paste the address of the API). nil if it isn't one (and for an empty text).
    static func normalizedEndpoint(_ text: String) -> String? {
        guard var endpoint = ScrobbleServiceConfig.normalizedEndpoint(text) else { return nil }
        if endpoint.lowercased().hasSuffix("/rest") { endpoint.removeLast("/rest".count) }
        return endpoint
    }

    /// Why the settings can't be saved, nil if they can. The name has to be told apart from the `others`.
    func problem(among others: [SubsonicConnectionConfig]) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a name." }
        let sameName = { (other: SubsonicConnectionConfig) -> Bool in
            other.id != id && other.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if others.contains(where: sameName) { return "Another connection already has this name." }

        let publicText = publicEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let localText = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if publicText.isEmpty && localText.isEmpty { return "Enter the public or the local endpoint." }
        if !publicText.isEmpty && Self.normalizedEndpoint(publicText) == nil {
            return "Enter the public endpoint as an http:// or https:// URL."
        }
        if !localText.isEmpty && Self.normalizedEndpoint(localText) == nil {
            return "Enter the local endpoint as an http:// or https:// URL."
        }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the username." }
        if password.isEmpty { return "Enter the password." }
        return nil
    }

    /// The order the connections are listed in: by name, as a person would sort them.
    static func isOrderedBefore(_ a: SubsonicConnectionConfig, _ b: SubsonicConnectionConfig) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        if order != .orderedSame { return order == .orderedAscending }
        return a.id.uuidString < b.id.uuidString
    }
}

/// How much of what was downloaded from a server stays on disk after it was played (`SubsonicDownloads`).
///
/// Stored in the config as a number: GB for a limit, 0 for none, -1 for unlimited.
enum SubsonicCacheSize: Equatable, Hashable, Sendable {
    /// A file is deleted as soon as nothing needs it, and all files are deleted at launch and quit.
    case off
    /// Files are kept up to this many GB (`ConfigLimits.subsonicCacheMinGB`...`subsonicCacheMaxGB`); the least recently
    /// played go first.
    case limited(gigabytes: Int)
    /// Files are kept, nothing is ever deleted.
    case unlimited

    static let `default` = SubsonicCacheSize.limited(gigabytes: ConfigLimits.subsonicCacheDefaultGB)

    /// nil for a number that stands for nothing.
    init?(storedValue: Int) {
        switch storedValue {
        case 0: self = .off
        case -1: self = .unlimited
        case ConfigLimits.subsonicCacheMinGB...ConfigLimits.subsonicCacheMaxGB: self = .limited(gigabytes: storedValue)
        default: return nil
        }
    }

    var storedValue: Int {
        switch self {
        case .off: 0
        case .limited(let gigabytes): gigabytes
        case .unlimited: -1
        }
    }

    /// Downloaded files outlive their use.
    var keepsFiles: Bool { self != .off }


    var title: String {
        switch self {
        case .off: "None"
        case .limited(let gigabytes): "\(gigabytes) GB"
        case .unlimited: "Unlimited"
        }
    }
}

/// The two ways a server can be reached.
enum SubsonicRoute: String, CaseIterable, Sendable {
    /// The address in the local network: preferred whenever it answers.
    case local
    /// The address that works from anywhere.
    case `public`

    var title: String {
        switch self {
        case .local: "Local"
        case .public: "Public"
        }
    }
}
