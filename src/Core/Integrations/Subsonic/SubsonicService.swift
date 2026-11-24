// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network
import Observation

/// The Subsonic connections (the `subsonic` list of the config): what the user set up and, for the enabled ones, the
/// `SubsonicConnection` that talks to the server.
///
/// - An enabled connection pings its server when the app starts and whenever it is added, edited or switched on
///   (and with two addresses keeps looking at the local one, see `SubsonicConnection`).
/// - What happens on the way is not an error to the user, only a mark on the connection (`status(of:)`, runtime only:
///   it isn't saved), the same as with the scrobbling services.
/// - A change of the network makes the connections with two addresses look at them again at once.
@MainActor
@Observable
final class SubsonicService {
    static let shared = SubsonicService(configStore: .shared, covers: SubsonicCoverCache(directory: AppPaths.current.subsonicCacheDir))

    /// What is known about a connection since the app started.
    struct Status: Equatable {
        /// The last time the server was dealt with (a call, a ping); nil if it wasn't since the app started.
        var lastInteraction: Date?
        /// Why the last interaction failed; nil if it didn't.
        var error: String?
        /// The last interaction went through.
        var isOK = false
        /// The address it was about.
        var route: SubsonicRoute?
    }

    /// All connections, sorted by name.
    private(set) var connections: [SubsonicConnectionConfig]
    private(set) var statuses: [UUID: Status] = [:]

    /// Told the cache size of every connection whenever a connection is added, removed or edited (`SubsonicDownloads`
    /// listens; a connection that is no longer in it is one that was removed).
    @ObservationIgnored var onCachePoliciesChanged: (([UUID: SubsonicCacheSize]) -> Void)?
    /// Told when the list of connections changed (one added, removed, edited, switched on or off): `SubsonicPlaylists`
    /// shows the playlists of the enabled ones.
    @ObservationIgnored var onConnectionsChanged: (() -> Void)?
    /// Told when the network changed (not for the first report at launch): worth looking at the servers again.
    @ObservationIgnored var onNetworkChanged: (() -> Void)?

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let pingTransport: (any HTTPTransport)?
    @ObservationIgnored private let covers: SubsonicCoverCache?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var runtimes: [UUID: SubsonicConnection] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var sawFirstPath = false

    /// `watchesNetwork`: look at the addresses again when the network changes. Tests turn it off.
    /// `covers`: where the covers that are fetched for playback are kept; nil = nowhere.
    init(configStore: ConfigStore,
         transport: any HTTPTransport = URLSessionTransport(timeout: SubsonicHTTP.requestTimeout),
         pingTransport: (any HTTPTransport)? = nil,
         covers: SubsonicCoverCache? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         watchesNetwork: Bool = true) {
        self.configStore = configStore
        self.transport = transport
        self.pingTransport = pingTransport
        self.covers = covers
        self.sleep = sleep
        connections = configStore.config.subsonic

        if connections.isEmpty {
            Log.info("subsonic: no connections set up")
        }
        for connection in connections {
            if connection.enabled {
                activate(connection)
            } else {
                Log.info("subsonic: \"\(connection.displayName)\" is disabled")
            }
        }
        if watchesNetwork { watchNetwork() }
    }

    func status(of id: UUID) -> Status {
        statuses[id] ?? Status()
    }

    /// The connections that are switched on, sorted by name.
    var enabledConnections: [SubsonicConnectionConfig] {
        connections.filter(\.enabled)
    }

    var hasEnabledConnections: Bool {
        connections.contains(where: \.enabled)
    }

    /// The connection to the server with this ID; nil if there is none or it is switched off.
    func connection(_ id: UUID) -> SubsonicConnection? {
        runtimes[id]
    }

    /// The cache size of every connection, the disabled ones too.
    var cachePolicies: [UUID: SubsonicCacheSize] {
        Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0.cacheSize) })
    }

    /// What the connection is called, for messages and the log (tracks can outlive their connection).
    func displayName(of id: UUID) -> String {
        connections.first { $0.id == id }?.displayName ?? "a removed connection"
    }

    /// A cover and where it came from.
    struct Cover: Equatable {
        let data: Data
        /// The server just gave it (it is not the copy on disk that was there).
        let isFromServer: Bool
    }

    /// The cover art `art` of the album `album` (its ID on the server) of a connection, for the Now Playing block. What was
    /// fetched before is kept per album (`SubsonicCoverCache`): the copy of this very cover is used without asking the server,
    /// a copy of another (older) cover of the album only when the server can't give the new one, which is also the case
    /// for a switched off connection. nil if there is none and the server doesn't have it.
    func coverArt(connection id: UUID, album: String, id art: String, size: Int?) async -> Data? {
        await cover(connection: id, album: album, id: art, size: size)?.data
    }

    /// Like `coverArt`, but says where the picture came from. `refresh`: the server is asked even if the copy on disk is
    /// of this very cover (which is then still the answer if the server can't give it).
    func cover(connection id: UUID, album: String, id art: String, size: Int?, refresh: Bool = false) async -> Cover? {
        let covers = covers
        var cached: SubsonicCoverCache.Hit?
        if let covers {
            cached = await Task.detached(priority: .userInitiated) {
                covers.lookup(connection: id, album: album, art: art, size: size)
            }.value
        }
        if !refresh, let cached, cached.isCurrent { return Cover(data: cached.data, isFromServer: false) }

        if let connection = runtimes[id], let data = try? await connection.coverArt(art, size: size) {
            if let covers {
                // Waited for: whoever asks next (the thumbnail, the next album start) finds the file.
                await Task.detached(priority: .utility) { covers.store(data, connection: id, album: album, art: art, size: size) }.value
            }
            return Cover(data: data, isFromServer: true)
        }
        return cached.map { Cover(data: $0.data, isFromServer: false) }
    }

    // MARK: - Editing

    /// Adds a connection (and starts it if it is enabled).
    func add(_ connection: SubsonicConnectionConfig) {
        let connection = connection.normalized
        guard !connections.contains(where: { $0.id == connection.id }) else { return update(connection) }
        save(connections + [connection])
        Log.info("subsonic: \"\(connection.displayName)\" added")
        if connection.enabled { activate(connection) }
        onConnectionsChanged?()
    }

    /// Replaces the connection with the same ID. The connection to the server is made again when how it is reached
    /// changes (another address, user or password) or it is switched on or off.
    func update(_ connection: SubsonicConnectionConfig) {
        let connection = connection.normalized
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return add(connection) }
        let old = connections[index]
        guard connection != old else { return }

        var list = connections
        list[index] = connection
        save(list)

        let sameConnection = connection.hasSameConnection(as: old)
        if sameConnection, connection.enabled == old.enabled {
            runtimes[connection.id]?.updateSettings(connection)
            Log.info("subsonic: \"\(connection.displayName)\" updated")
            onConnectionsChanged?()
            return
        }
        deactivate(connection.id)
        statuses[connection.id] = nil
        Log.info("subsonic: \"\(connection.displayName)\" updated" + (connection.enabled ? "" : " and disabled"))
        if connection.enabled { activate(connection) }
        onConnectionsChanged?()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard var connection = connections.first(where: { $0.id == id }) else { return }
        connection.enabled = enabled
        update(connection)
    }

    /// Removes a connection (and what was downloaded from it). Tracks that came from it stay in the playlists, and can't
    /// be played.
    func remove(_ id: UUID) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        deactivate(id)
        statuses[id] = nil
        save(connections.filter { $0.id != id })
        Log.info("subsonic: \"\(connection.displayName)\" removed")
        onConnectionsChanged?()
    }

    private func save(_ list: [SubsonicConnectionConfig]) {
        connections = list.sorted(by: SubsonicConnectionConfig.isOrderedBefore)
        let saved = connections
        configStore.update { $0.subsonic = saved }
        onCachePoliciesChanged?(cachePolicies)
    }

    // MARK: - Testing

    /// Pings every address of `connection` as it is (it needn't be saved), and says what came of each. Doesn't touch
    /// the running connections.
    func test(_ connection: SubsonicConnectionConfig) async -> [SubsonicConnection.RouteTest] {
        let connection = connection.normalized
        Log.info("subsonic: testing the connection to \"\(connection.displayName)\"")
        let results = await SubsonicConnection(config: connection, transport: transport, pingTransport: pingTransport,
                                               sleep: sleep).test()
        for result in results {
            switch result.outcome {
            case .success(let info):
                Log.info("subsonic: test of \"\(connection.displayName)\", \(result.route.title.lowercased()) address: \(info)")
            case .failure(let error):
                Log.error("subsonic: test of \"\(connection.displayName)\", \(result.route.title.lowercased()) address failed: \(error)")
            }
        }
        return results
    }

    /// `message` as the start of a sentence, with a full stop.
    static func sentence(_ message: String) -> String {
        let text = message.prefix(1).uppercased() + message.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    // MARK: - Connections

    private func activate(_ config: SubsonicConnectionConfig) {
        let id = config.id
        let connection = SubsonicConnection(config: config, transport: transport, pingTransport: pingTransport, sleep: sleep)
        connection.onActivity = { [weak self, weak connection] activity in
            guard let self, let connection, self.runtimes[id] === connection else { return }
            self.record(activity, id: id)
        }
        runtimes[id] = connection
        let routes = config.routes.map { "\($0.title.lowercased()): \(config.endpoint($0) ?? "")" }.joined(separator: ", ")
        Log.info("subsonic: \"\(config.displayName)\" is enabled (\(routes))")
        connection.start()
    }

    private func deactivate(_ id: UUID) {
        runtimes.removeValue(forKey: id)?.stop()
    }

    private func record(_ activity: SubsonicConnection.Activity, id: UUID) {
        statuses[id] = Status(lastInteraction: activity.date, error: activity.error?.message,
                              isOK: activity.error == nil, route: activity.route)
    }

    // MARK: - Network

    private func watchNetwork() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "wtf.d7.icanhazmusic.subsonic-network", qos: .utility))
    }

    private func networkChanged() {
        // The first update is the state at launch, which the first ping of every connection is looking at already.
        guard sawFirstPath else {
            sawFirstPath = true
            return
        }
        for connection in runtimes.values where connection.config.routes.count == 2 {
            Task { await connection.probe() }
        }
        onNetworkChanged?()
    }
}

/// What `SubsonicDownloads` asks of the connections.
extension SubsonicService: SubsonicDownloadProvider {
    func downloadTarget(connection id: UUID, songID: String, avoiding: Set<SubsonicRoute>) async throws -> SubsonicDownloadTarget? {
        guard let connection = runtimes[id] else {
            if let known = connections.first(where: { $0.id == id }) {
                throw SubsonicError(.rejected, "its connection \"\(known.displayName)\" is switched off")
            }
            throw SubsonicError(.rejected, "its connection was removed")
        }
        let preferred = await connection.resolvedRoute()
        let routes = ([preferred].compactMap { $0 } + connection.config.routes).filter { !avoiding.contains($0) }
        guard let route = routes.first, let url = connection.url("download", [("id", songID)], route: route) else { return nil }
        return SubsonicDownloadTarget(url: url, route: route)
    }

    func downloadDidFinish(connection id: UUID, route: SubsonicRoute, error: SubsonicError?) async {
        runtimes[id]?.noteResult(error, on: route)
    }
}
