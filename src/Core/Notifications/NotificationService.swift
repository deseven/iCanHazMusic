// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

/// What a notification says. Plain text, so what is shown can be tested without a notification center.
struct NotificationMessage: Equatable, Sendable {
    var title: String
    var subtitle = ""
    var body = ""
}

/// Shows a message to the user. Delivering a message replaces the one delivered before: there is never more than one.
@MainActor
protocol NotificationDelivery: AnyObject {
    /// `cover`: the encoded image (JPEG/PNG bytes) to show with the message, if there is one.
    func deliver(_ message: NotificationMessage, cover: Data?)
}

/// System notifications about playback, for when the app isn't in front: the track that starts and the end of the
/// playlist (or of the queue, with "Stop at queue end").
///
/// A `PlaybackListener`, like `LastFMService` and `LyricsService`. The notifications replace each other (see
/// `NotificationDelivery`), so the one on screen is always the latest: a track that starts replaces the previous
/// track's, and the end of the playlist replaces the last track's.
///
/// `isEnabled` (config `general.playback_notifications`, on by default) turns all of it off: nothing is sent, so the
/// system doesn't even ask for permission.
@MainActor
@Observable
final class NotificationService: PlaybackListener {
    static let shared = NotificationService(delivery: SystemNotificationDelivery(), coverStore: .shared, configStore: .shared)

    /// Send notifications. Persisted in the config.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            configStore?.update { $0.general.playbackNotifications = isEnabled }
            Log.info("playback notifications: \(isEnabled ? "on" : "off")")
        }
    }

    @ObservationIgnored private let delivery: NotificationDelivery
    @ObservationIgnored private let coverStore: CoverStore
    @ObservationIgnored private let configStore: ConfigStore?

    /// `configStore`: where `isEnabled` is read from and kept; `nil` = on, and nothing is persisted.
    init(delivery: NotificationDelivery, coverStore: CoverStore, configStore: ConfigStore? = nil) {
        self.delivery = delivery
        self.coverStore = coverStore
        self.configStore = configStore
        isEnabled = configStore?.config.general.playbackNotifications ?? true
    }

    func trackDidStart(_ track: PlayedTrack) {
        guard isEnabled else { return }
        let cover = track.coverKey.flatMap { coverStore.data(for: $0) }
        delivery.deliver(Self.message(starting: track), cover: cover)
    }

    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval) {}

    func playlistDidEnd(playlist: String) {
        guard isEnabled else { return }
        delivery.deliver(Self.message(playlistEnded: playlist), cover: nil)
    }

    func queueDidEnd() {
        guard isEnabled else { return }
        delivery.deliver(Self.messageQueueEnded, cover: nil)
    }

    // MARK: - Texts

    /// Title, then the artist, then the album and the duration.
    static func message(starting track: PlayedTrack) -> NotificationMessage {
        var details: [String] = []
        if !track.album.isEmpty, track.album != TagFallback.album { details.append(track.album) }
        if track.duration >= 1 { details.append(formatDuration(track.duration)) }
        return NotificationMessage(title: track.title, subtitle: track.artist, body: details.joined(separator: " · "))
    }

    static func message(playlistEnded playlist: String) -> NotificationMessage {
        NotificationMessage(title: "Playlist ended", body: "Finished playing “\(playlist)”.")
    }

    static let messageQueueEnded = NotificationMessage(title: "Queue ended", body: "Finished playing the queue.")

    /// `3:05`, or `1:02:03` from an hour on.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded())
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
