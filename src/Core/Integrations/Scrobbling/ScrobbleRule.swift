// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// When a played track is reported to the scrobbling services, and when it is not. The rule is the one of
/// Audioscrobbler and ListenBrainz alike.
///
/// - A track counts as listened to after half of its length or `maxListening` seconds, whichever comes first.
/// - Tracks that are not longer than `minimumDuration` are never scrobbled.
/// - A track needs an artist and a title of its own (no "Unknown Artist").
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

    /// The services need at least the artist and the title, and they have to be real ones: a track without tags
    /// ("Unknown Artist") is nothing to report.
    static func isReportable(_ track: PlayedTrack) -> Bool {
        !track.artist.trimmingCharacters(in: .whitespaces).isEmpty
            && !track.title.trimmingCharacters(in: .whitespaces).isEmpty
            && track.hasTags
    }

    static func isScrobbleWorthy(_ track: PlayedTrack, playedSeconds: TimeInterval) -> Bool {
        track.duration >= minimumDuration && playedSeconds >= threshold(forDuration: track.duration)
    }
}
