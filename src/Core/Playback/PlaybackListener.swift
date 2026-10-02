import Foundation

/// A track as it was played, for whoever wants to know what the user listens to (Last.fm).
struct PlayedTrack: Equatable, Sendable {
    let artist: String
    let title: String
    let album: String
    /// Seconds; 0 if unknown.
    var duration: TimeInterval
    /// When the track started playing.
    let startedAt: Date
}

/// Told by `PlaybackState` when a track starts and when it is left, however that happens (the next track, the user
/// picking another one, stop, the end of the playlist).
@MainActor
protocol PlaybackListener: AnyObject {
    func trackDidStart(_ track: PlayedTrack)

    /// `playedSeconds` is the time actually listened to: seeking forward doesn't add to it, pauses don't either.
    /// `track.duration` is the corrected one (from the opened file) if playback found a different one.
    func trackDidEnd(_ track: PlayedTrack, playedSeconds: TimeInterval)
}

/// How much of the current track has been listened to, from the positions reported while it plays.
struct PlayProgress {
    /// Position steps bigger than this (seeking, a stalled main thread) are not listening time. The position is
    /// read every 250 ms while playing.
    static let maxStep: TimeInterval = 1.5

    let track: PlayedTrack
    private(set) var played: TimeInterval = 0
    private var lastPosition: TimeInterval = 0

    init(track: PlayedTrack) {
        self.track = track
    }

    mutating func observe(position: TimeInterval) {
        let step = position - lastPosition
        lastPosition = position
        if step > 0, step <= Self.maxStep { played += step }
    }
}
