// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// When a played track is reported to the scrobbling services, and when it is not. The rule is the one of
/// Audioscrobbler and ListenBrainz alike.
///
/// - A track counts as listened to after half of its length or `maxListening` seconds, whichever comes first.
/// - Tracks that are not longer than `minimumDuration` are never scrobbled.
/// - A track needs an artist and a title of its own (the data, see `TagFallback`: what the UI shows for a missing one
///   doesn't count). The album is optional: without one it is sent empty (Audioscrobbler) or left out (ListenBrainz).
enum ScrobbleRule {
    /// A track counts as listened to at this share of its duration.
    static let scrobbleShare = 0.5
    /// ... or after this many seconds if that comes first.
    static let maxListening: TimeInterval = 240
    /// Shorter tracks are never scrobbled.
    static let minimumDuration: TimeInterval = 30

    /// How long a track of `duration` seconds has to be listened to.
    static func threshold(forDuration duration: TimeInterval) -> TimeInterval {
        min(duration * scrobbleShare, maxListening)
    }

    /// The services need at least the artist and the title, and they have to be real ones: a track without them
    /// is nothing to report.
    static func isReportable(_ track: PlayedTrack) -> Bool {
        track.hasTags
    }

    static func isScrobbleWorthy(_ track: PlayedTrack, playedSeconds: TimeInterval) -> Bool {
        track.duration >= minimumDuration && playedSeconds >= threshold(forDuration: track.duration)
    }
}
