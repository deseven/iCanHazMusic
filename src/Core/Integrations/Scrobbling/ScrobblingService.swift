// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// The scrobbling services (the `scrobbling` list of the config): what the user set up, and, for the enabled ones,
/// the connection to them and the now playing updates and scrobbles for what `PlaybackState` plays.
///
/// - An enabled service is authenticated when the app starts and whenever it is added, edited or switched on.
/// - A track that starts is announced as now playing (to the services that take it).
/// - A track that was listened to enough (`ScrobbleRule`) is scrobbled when it is left, whatever the reason is. The
///   scrobble carries the time the track started at.
/// - Every service has its own `ScrobbleQueue`: in the background, one call at a time, with retries, and a service
///   that is down doesn't hold up the others.
///
/// What goes wrong is not an error to the user, only a mark on the service (`status(of:)`, runtime only: it isn't
/// saved). The next call that goes through takes it away, and every new track is a new try, so a service that was
/// unreachable or got fixed is picked up again without the user doing anything.
@MainActor
@Observable
final class ScrobblingService: PlaybackListener {
    static let shared = ScrobblingService(configStore: .shared)

    /// What is known about a service since the app started.
    struct Status: Equatable {
        /// When the last scrobble that went through was sent; nil if none did.
        var lastScrobble: Date?
        /// Why the last try (authentication, now playing or scrobble) failed; nil if it didn't.
        var error: String?
        /// The last try (authentication, now playing or scrobble) went through.
        var isOK = false
    }

    enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    /// All services, sorted by name.
    private(set) var services: [ScrobbleServiceConfig]
    private(set) var statuses: [UUID: Status] = [:]

    private struct Runtime {
        let queue: ScrobbleQueue
        /// The protocol has a way to clear the now playing status.
        let canClearNowPlaying: Bool
        /// Tells this connection from an earlier one of the same service (its late callbacks are ignored).
        let generation: Int
    }

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var runtimes: [UUID: Runtime] = [:]
    @ObservationIgnored private var nextGeneration = 0

    init(configStore: ConfigStore,
         transport: any HTTPTransport = URLSessionTransport(timeout: ScrobbleHTTP.requestTimeout),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.configStore = configStore
        self.transport = transport
        self.sleep = sleep
        services = configStore.config.scrobbling

        if services.isEmpty {
            Log.info("scrobbling: no services set up")
        }
        for service in services {
            if service.enabled {
                activate(service)
            } else {
                Log.info("scrobbling: \"\(service.displayName)\" (\(service.type.title), \(service.endpoint)) is disabled")
            }
        }
    }

    func status(of id: UUID) -> Status {
        statuses[id] ?? Status()
    }

    // MARK: - Editing

    /// Adds a service (and starts it if it is enabled).
    func add(_ service: ScrobbleServiceConfig) {
        let service = service.normalized
        guard !services.contains(where: { $0.id == service.id }) else { return update(service) }
        save(services + [service])
        Log.info("scrobbling: \"\(service.displayName)\" added")
        if service.enabled { activate(service) }
    }

    /// Replaces the service with the same ID. What is pending for it is dropped when the connection changes (another
    /// endpoint, account or secret) or it is switched on or off; the connection is then made again.
    func update(_ service: ScrobbleServiceConfig) {
        let service = service.normalized
        guard let index = services.firstIndex(where: { $0.id == service.id }) else { return add(service) }
        let old = services[index]
        guard service != old else { return }

        var list = services
        list[index] = service
        save(list)

        let sameConnection = service.hasSameConnection(as: old)
        guard !sameConnection || service.enabled != old.enabled else {
            Log.info("scrobbling: \"\(service.displayName)\" updated")
            return
        }
        deactivate(service.id)
        if sameConnection {
            statuses[service.id]?.error = nil
            statuses[service.id]?.isOK = false
        } else {
            statuses[service.id] = nil
        }
        Log.info("scrobbling: \"\(service.displayName)\" updated" + (service.enabled ? "" : " and disabled"))
        if service.enabled { activate(service) }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard var service = services.first(where: { $0.id == id }) else { return }
        service.enabled = enabled
        update(service)
    }

    /// Removes a service and forgets what is pending for it.
    func remove(_ id: UUID) {
        guard let service = services.first(where: { $0.id == id }) else { return }
        deactivate(id)
        statuses[id] = nil
        save(services.filter { $0.id != id })
        Log.info("scrobbling: \"\(service.displayName)\" removed")
    }

    private func save(_ list: [ScrobbleServiceConfig]) {
        services = list.sorted(by: ScrobbleServiceConfig.isOrderedBefore)
        let saved = services
        configStore.update { $0.scrobbling = saved }
    }

    // MARK: - Testing

    /// Tries `service` as it is (it needn't be saved): authenticates, and says what came of it. Doesn't touch the
    /// running connections.
    func test(_ service: ScrobbleServiceConfig) async -> TestResult {
        let service = service.normalized
        let name = service.displayName
        guard ScrobbleServiceConfig.normalizedEndpoint(service.endpoint) != nil else {
            return .failure("The endpoint isn't an http:// or https:// URL.")
        }
        Log.info("scrobbling: testing the connection to \"\(name)\" (\(service.type.title), \(service.endpoint))")
        do {
            let account = try await service.makeClient(transport: transport).authenticate()
            Log.info("scrobbling: test of \"\(name)\" succeeded" + (account.map { ", account \($0)" } ?? ""))
            return .success(account.map { "Success: connected as \($0)." } ?? "Success: the service accepted the connection.")
        } catch is CancellationError {
            return .failure("Cancelled.")
        } catch let error as ScrobbleError {
            Log.error("scrobbling: test of \"\(name)\" failed: \(error)")
            return .failure(Self.sentence(error.message))
        } catch {
            Log.error("scrobbling: test of \"\(name)\" failed: \(error.localizedDescription)")
            return .failure(Self.sentence(error.localizedDescription))
        }
    }

    /// `message` as the start of a sentence.
    static func sentence(_ message: String) -> String {
        message.prefix(1).uppercased() + message.dropFirst()
    }

    // MARK: - Connections

    private func activate(_ service: ScrobbleServiceConfig) {
        nextGeneration += 1
        let generation = nextGeneration
        let id = service.id
        let client = service.makeClient(transport: transport)
        let queue = ScrobbleQueue(
            name: service.displayName,
            client: client,
            sleep: sleep,
            onDelivered: { [weak self] call in self?.delivered(call, id: id, generation: generation) },
            onFailure: { [weak self] error in self?.failed(error, id: id, generation: generation) }
        )
        runtimes[id] = Runtime(queue: queue, canClearNowPlaying: client.canClearNowPlaying, generation: generation)
        Log.info("scrobbling: \"\(service.displayName)\" (\(service.type.title), \(service.endpoint)) is enabled"
            + (service.submitNowPlaying ? "" : ", without now playing"))
        queue.enqueue(.authenticate, label: "authentication")
    }

    private func deactivate(_ id: UUID) {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        if runtime.queue.pendingCount > 0 {
            Log.info("scrobbling: dropped \(runtime.queue.pendingCount) pending call(s) of the previous connection")
        }
        runtime.queue.cancelAll()
    }

    private func delivered(_ call: ScrobbleQueue.Call, id: UUID, generation: Int) {
        guard runtimes[id]?.generation == generation else { return }
        var status = statuses[id] ?? Status()
        status.error = nil
        status.isOK = true
        if case .scrobble = call { status.lastScrobble = Date() }
        statuses[id] = status
    }

    private func failed(_ error: ScrobbleError, id: UUID, generation: Int) {
        guard runtimes[id]?.generation == generation else { return }
        statuses[id, default: Status()].error = error.message
        statuses[id, default: Status()].isOK = false
    }

    // MARK: - Playback

    func trackDidStart(_ track: PlayedTrack) {
        guard ScrobbleRule.isReportable(track) else { return }
        for service in services where service.submitNowPlaying {
            runtimes[service.id]?.queue.enqueue(.nowPlaying(track), label: "now playing \(track.artist) - \(track.title)")
        }
    }

    /// Some servers don't clear the now playing status when nothing plays any more: those that can be told are.
    func playbackDidStop() {
        for service in services where service.submitNowPlaying {
            guard let runtime = runtimes[service.id], runtime.canClearNowPlaying else { continue }
            runtime.queue.enqueue(.clearNowPlaying, label: "clearing now playing")
        }
    }

    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval) {
        guard ScrobbleRule.isReportable(track), ScrobbleRule.isScrobbleWorthy(track, playedSeconds: playedSeconds) else { return }
        for service in services {
            runtimes[service.id]?.queue.enqueue(.scrobble(track), label: "scrobble \(track.artist) - \(track.title)")
        }
    }
}
