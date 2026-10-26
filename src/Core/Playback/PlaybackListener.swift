// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A track as it was played, for whoever wants to know what the user listens to (Last.fm).
struct PlayedTrack: Equatable, Sendable {
    let artist: String
    let title: String
    let album: String
    /// Seconds; 0 if unknown.
    var duration: TimeInterval
    /// When the track started playing (its audio, not the command).
    var startedAt: Date
    /// `AlbumKey` of the track's album, which is what its cover is cached under (`CoverStore`); nil if unknown.
    var coverKey: String? = nil
    /// The file that plays; nil if unknown.
    var url: URL? = nil
    /// Set if the track is a part of `url` (a track of a CUE sheet).
    var cue: CueSlice? = nil

    /// What plays, if known.
    var source: PlaybackSource? {
        guard let url else { return nil }
        return PlaybackSource(url: url, start: cue?.start ?? 0, end: cue?.end)
    }

    /// The track has an artist and a title of its own; without ("Unknown Artist") nobody outside can be told about
    /// it or asked for its lyrics.
    var hasTags: Bool { TagFallback.isIdentified(artist: artist, title: title) }
}

/// Told by `PlaybackState` when a track starts and when it is left, however that happens (the next track, the user
/// picking another one, stop, the end of the playlist). A track "starts" when its audio does (the file was opened and
/// decoded), not when it is picked: one that can't be played (a file that is gone, a share that doesn't answer) is
/// never announced, and neither is its end.
@MainActor
protocol PlaybackListener: AnyObject {
    func trackDidStart(_ track: PlayedTrack)

    /// `playedSeconds` is the time actually listened to: seeking forward doesn't add to it, pauses don't either.
    /// `track.duration` is the corrected one (from the opened file) if playback found a different one.
    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval)

    /// Playback ran out of tracks by itself (not stopped by the user) and `playlist` was played to its end.
    /// Comes after the `trackDidEnd` of the last track.
    func playlistDidEnd(playlist: String)

    /// The queue was played through by itself and "Stop at queue end" stopped playback (not when the user stopped).
    /// Comes after the `trackDidEnd` of the last queued track.
    func queueDidEnd()
}

extension PlaybackListener {
    func playlistDidEnd(playlist: String) {}
    func queueDidEnd() {}
}

/// How much of the current track has been listened to, from the positions reported while it plays.
struct PlayProgress {
    /// Position steps bigger than this (seeking, a stalled main thread) are not listening time. The position is
    /// read every 250 ms while playing.
    static let maxStep: TimeInterval = 1.5

    let track: PlayedTrack
    /// Where the track was picked up after the app was restarted (0: from its start). What was before that was
    /// listened to by an earlier run, which is not known any more, see `listened(ofDuration:)`.
    let resumedAt: TimeInterval
    /// Listening done since the track started or was picked up.
    private(set) var played: TimeInterval = 0
    private var lastPosition: TimeInterval

    init(track: PlayedTrack, resumedAt: TimeInterval = 0) {
        self.track = track
        self.resumedAt = resumedAt
        lastPosition = resumedAt
    }

    mutating func observe(position: TimeInterval) {
        let step = position - lastPosition
        lastPosition = position
        if step > 0, step <= Self.maxStep { played += step }
    }

    /// What counts as listened to, for a track `duration` seconds long. A track that was picked up at the share of
    /// its length that Last.fm scrobbles at, or later, is taken to have been listened to up to there (the run before
    /// can't say, and the position is all that was kept); a track picked up earlier counts from scratch.
    @MainActor
    func listened(ofDuration duration: TimeInterval) -> TimeInterval {
        guard duration > 0, resumedAt >= duration * LastFMService.scrobbleThreshold else { return played }
        return min(played + resumedAt, duration)
    }
}
