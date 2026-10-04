import Foundation
import Observation

/// The Last.fm integration: whether the app is connected to an account (kept in the config), the connecting itself,
/// and, while connected, the now playing updates and scrobbles for what `PlaybackState` plays.
///
/// - A track that starts is announced as now playing.
/// - A track that was played to at least half of its length (and is longer than 30 seconds, below that Last.fm
///   doesn't take scrobbles) is scrobbled when it is left, whatever the reason is. The scrobble carries the time
///   the track started at.
/// - Everything goes through a `LastFMQueue`: in the background, one call at a time, with retries.
/// - If Last.fm refuses the session for good, the integration disconnects itself and `onConnectionLost` tells why.
///
/// Disconnecting drops everything pending and removes the session from the config.
@MainActor
@Observable
final class LastFMService: PlaybackListener {
    static let shared = LastFMService(configStore: .shared, credentials: .bundled)

    /// A track counts as listened to at this share of its duration.
    static let scrobbleThreshold = 0.5
    /// Shorter tracks are never scrobbled.
    static let minimumDuration: TimeInterval = 30

    /// The account the app is connected to; nil if it isn't.
    private(set) var username: String?
    /// The user is being asked to confirm the connection on Last.fm.
    private(set) var isAuthorizing = false

    var isConnected: Bool { username != nil }
    /// The app has Last.fm credentials at all (see `LastFMCredentials`).
    var isAvailable: Bool { credentials != nil }

    /// Called when Last.fm stopped accepting the session and the integration disconnected itself; gets the
    /// explanation for the user.
    @ObservationIgnored var onConnectionLost: (@MainActor (String) -> Void)?

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let credentials: LastFMCredentials?
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var queue: LastFMQueue?
    @ObservationIgnored private var auth: LastFMAuth?
    @ObservationIgnored private var authTask: Task<LastFMAuth.Outcome, Never>?

    init(configStore: ConfigStore, credentials: LastFMCredentials?,
         transport: any HTTPTransport = URLSessionTransport(timeout: LastFMAPI.requestTimeout),
         pollInterval: Duration = LastFMAuth.defaultPollInterval,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.configStore = configStore
        self.credentials = credentials
        self.transport = transport
        self.pollInterval = pollInterval
        self.sleep = sleep

        let saved = configStore.config.integrations.lastfm
        if saved.isConnected {
            if credentials != nil {
                activate(LastFMSession(key: saved.session, username: saved.username))
            } else {
                // Keep the session in the config (this build can't use it), but don't pretend to scrobble.
                Log.error("last.fm: connected as \(saved.username), but this build has no Last.fm credentials")
            }
        }
    }

    // MARK: - Connecting

    /// Runs the authorization: opens the confirmation page through `openURL` and waits until the user confirmed (or
    /// `abortConnecting()`). On success the session is saved and the integration is active.
    func connect(openURL: @escaping (URL) -> Void) async -> LastFMAuth.Outcome {
        guard let credentials else {
            return .failed("This build of \(AppConstants.appName) has no Last.fm credentials.")
        }
        guard !isConnected, !isAuthorizing else { return .aborted }

        let auth = LastFMAuth(client: LastFMClient(credentials: credentials, transport: transport),
                              pollInterval: pollInterval, openURL: openURL)
        let task = Task { await auth.run() }
        self.auth = auth
        authTask = task
        isAuthorizing = true

        let outcome = await task.value
        isAuthorizing = false
        self.auth = nil
        authTask = nil

        if case .connected(let session) = outcome {
            configStore.update { $0.integrations.lastfm = AppConfig.Integrations.LastFM(session: session.key, username: session.username) }
            activate(session)
        }
        return outcome
    }

    /// Cancels the authorization that is running, if any.
    func abortConnecting() {
        authTask?.cancel()
    }

    /// The app came back to the front: if the user is confirming the connection, that's likely done.
    func appDidBecomeActive() {
        auth?.checkNow()
    }

    // MARK: - Disconnecting

    /// Drops everything pending and forgets the account.
    func disconnect() {
        queue?.cancelAll()
        queue = nil
        username = nil
        configStore.update { $0.integrations.lastfm = AppConfig.Integrations.LastFM() }
        Log.info("last.fm: disconnected")
    }

    private func activate(_ session: LastFMSession) {
        guard let credentials else { return }
        username = session.username
        queue = LastFMQueue(
            client: LastFMClient(credentials: credentials, transport: transport),
            sessionKey: session.key,
            sleep: sleep,
            onAuthenticationFailure: { [weak self] error in self?.sessionWasRefused(error) }
        )
    }

    private func sessionWasRefused(_ error: LastFMError) {
        let account = username.map { " as \($0)" } ?? ""
        disconnect()
        onConnectionLost?("Last.fm no longer accepts the connection\(account): \(error.message).\n\n"
            + "Scrobbling is turned off. You can connect Last.fm again in Preferences, under Integrations.")
    }

    // MARK: - Playback

    func trackDidStart(_ track: PlayedTrack) {
        guard let queue, Self.isReportable(track) else { return }
        queue.enqueue(.updateNowPlaying(track), label: "now playing \(track.artist) - \(track.title)")
    }

    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval) {
        guard let queue, Self.isReportable(track), Self.isScrobbleWorthy(track, playedSeconds: playedSeconds) else { return }
        queue.enqueue(.scrobble(track), label: "scrobble \(track.artist) - \(track.title)")
    }

    /// Last.fm needs at least the artist and the title, and they have to be real ones: a track without tags
    /// ("Unknown Artist") is nothing to report.
    static func isReportable(_ track: PlayedTrack) -> Bool {
        !track.artist.trimmingCharacters(in: .whitespaces).isEmpty
            && !track.title.trimmingCharacters(in: .whitespaces).isEmpty
            && track.hasTags
    }

    static func isScrobbleWorthy(_ track: PlayedTrack, playedSeconds: TimeInterval) -> Bool {
        track.duration >= minimumDuration && playedSeconds >= track.duration * scrobbleThreshold
    }
}
