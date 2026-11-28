// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// Shows what plays on the user's Discord profile (Rich Presence), through the local IPC socket of the Discord
/// desktop client (`DiscordIPCConnection`): no login, no SDK, Discord only has to run on the same Mac.
///
/// - On while `isEnabled` (config `integrations.discord.enabled`, off by default) and the bundle has an application
///   ID (`appID`: `ICHM_DISCORD_APP_ID` from `.env`, put into `Info.plist` obfuscated by `build.sh`; a build without
///   it, like plain `swift build`, can't do this at all).
/// - Shows a track while it plays (`DiscordActivity`); a paused or stopped player shows nothing, and neither does a
///   track without tags (`PlayedTrack.hasTags`, as for scrobbling).
/// - Connects only when there is something to show. When Discord isn't running (or goes away) it tries again every
///   `retryInterval` while there is; quitting the app (or turning this off) closes the connection and Discord clears
///   the activity by itself.
/// - Discord allows 5 updates per 20 seconds: updates are at least `minSendInterval` apart (and a little delayed, so
///   that the end of a track and the start of the next one are a single update); a seek or drift of less than
///   `DiscordActivity.timeTolerance` isn't sent.
@MainActor
@Observable
final class DiscordPresence: PlaybackListener {
    static let shared = DiscordPresence(configStore: .shared, appID: DiscordPresence.bundledAppID)

    /// `Info.plist` key of the obfuscated application ID (`Obfuscation`).
    nonisolated static let appIDInfoKey = "ICHMDiscordAppID"

    /// The application ID of the running bundle, if it has a valid one.
    nonisolated static var bundledAppID: String? {
        appID(fromInfo: Bundle.main.infoDictionary)
    }

    nonisolated static func appID(fromInfo info: [String: Any]?) -> String? {
        guard let encoded = info?[appIDInfoKey] as? String,
              let id = Obfuscation.deobfuscated(encoded),
              !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { return nil }
        return id
    }

    static let retryInterval: Duration = .seconds(20)
    static let minSendInterval: TimeInterval = 4
    static let sendDelay: TimeInterval = 0.5

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    /// Persisted in the config.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            configStore.update { $0.integrations.discord.enabled = isEnabled }
            Log.info("discord: \(isEnabled ? "on" : "off")")
            refresh()
        }
    }

    /// The build has an application ID, without it this can't work.
    var isAvailable: Bool { appID != nil }

    private(set) var connectionState = ConnectionState.disconnected
    /// Why the last connection attempt failed or the connection was lost; nil once connected.
    private(set) var problem: String?

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let appID: String?
    @ObservationIgnored private weak var playback: PlaybackState?
    /// The track that plays (or is paused), from the listener calls.
    @ObservationIgnored private var track: PlayedTrack?
    @ObservationIgnored private var connection: DiscordIPCConnection?
    /// What Discord shows now (nil: nothing, as on a fresh connection).
    @ObservationIgnored private var shown: DiscordActivity?
    @ObservationIgnored private var lastSendAt: Date?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init(configStore: ConfigStore, appID: String?) {
        self.configStore = configStore
        self.appID = appID
        isEnabled = configStore.config.integrations.discord.enabled
    }

    /// Follows `playback` from now on (its pause, resume and seeks; the tracks come through the listener calls).
    func start(playback: PlaybackState) {
        self.playback = playback
        if isEnabled, appID == nil { Log.info("discord: no application ID in this build, rich presence unavailable") }
        observePlayback()
        refresh()
    }

    // MARK: - PlaybackListener

    func trackDidStart(_ track: PlayedTrack) {
        self.track = track
        refresh()
    }

    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval) {
        self.track = nil
        refresh()
    }

    func playbackDidStop() {
        track = nil
        refresh()
    }

    // MARK: - Following playback

    private func observePlayback() {
        guard let playback else { return }
        withObservationTracking {
            _ = playback.status
            _ = playback.anchor
            _ = playback.duration
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observePlayback()
            }
        }
    }

    /// What should be shown now.
    private var wanted: DiscordActivity? {
        guard isEnabled, appID != nil, let playback, playback.status == .playing, let track else { return nil }
        let position = playback.anchor.position(at: ProcessInfo.processInfo.systemUptime)
        let duration = playback.duration > 0 ? playback.duration : track.duration
        return DiscordActivity(track: track, position: position, duration: duration)
    }

    private static func isClose(_ a: DiscordActivity?, _ b: DiscordActivity?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.isClose(to: b)
        default: false
        }
    }

    /// Brings Discord in line with what plays: connects, schedules an update, or disconnects.
    private func refresh() {
        guard isEnabled, let appID else { return disconnect() }
        let wanted = self.wanted
        switch connectionState {
        case .disconnected:
            if wanted != nil, retryTask == nil { connect(appID: appID) }
        case .connecting:
            break   // `refresh` again once it is through
        case .connected:
            if !Self.isClose(wanted, shown) { scheduleSend() }
        }
    }

    // MARK: - Connection

    private func connect(appID: String) {
        connectionState = .connecting
        let connection = DiscordIPCConnection { [weak self] reason in
            Task { @MainActor in self?.connectionLost(reason) }
        }
        self.connection = connection
        Task {
            do {
                try await connection.open(clientID: appID)
                guard self.connection === connection else { return connection.close() }
                connectionState = .connected
                problem = nil
                shown = nil
                Log.info("discord: connected")
                refresh()
            } catch {
                guard self.connection === connection else { return }
                self.connection = nil
                connectionState = .disconnected
                let reason = "\(error)"
                if reason != problem { Log.info("discord: can't connect: \(reason)") }
                problem = reason
                scheduleRetry()
            }
        }
    }

    private func connectionLost(_ reason: String) {
        guard connection != nil, connectionState == .connected else { return }
        connection = nil
        connectionState = .disconnected
        shown = nil
        sendTask?.cancel()
        sendTask = nil
        problem = reason
        Log.info("discord: connection lost: \(reason)")
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retryInterval)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.refresh()
        }
    }

    private func disconnect() {
        sendTask?.cancel()
        sendTask = nil
        retryTask?.cancel()
        retryTask = nil
        problem = nil
        shown = nil
        guard let connection else { return }
        self.connection = nil
        connectionState = .disconnected
        connection.close()
        Log.info("discord: disconnected")
    }

    // MARK: - Updates

    private func scheduleSend() {
        guard sendTask == nil else { return }
        let now = Date()
        let earliest = lastSendAt.map { $0.addingTimeInterval(Self.minSendInterval) } ?? now
        let delay = max(Self.sendDelay, earliest.timeIntervalSince(now))
        sendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.send()
        }
    }

    /// Sends what is wanted at this moment (it may have changed again while the update waited).
    private func send() async {
        sendTask = nil
        guard connectionState == .connected, let connection else { return }
        let wanted = self.wanted
        guard !Self.isClose(wanted, shown) else { return }
        lastSendAt = Date()
        shown = wanted
        guard await connection.send(DiscordActivity.command(wanted)) else { return }   // `connectionLost` follows
        // Something else may have changed while it was on its way.
        if self.connection === connection, !Self.isClose(self.wanted, shown) { scheduleSend() }
    }
}
