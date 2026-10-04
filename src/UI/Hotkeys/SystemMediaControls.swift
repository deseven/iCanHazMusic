import AppKit
import MediaPlayer
import Observation

/// Lets the media keys (and everything else that sends the system's remote commands: headset buttons, AirPods,
/// the Touch Bar, Control Center) control the player.
///
/// This is the system's own way, no permissions needed: the app registers handlers with `MPRemoteCommandCenter` and
/// publishes what plays to `MPNowPlayingInfoCenter`; the system sends the keys to the app it considers to be the
/// "now playing" one, which it picks by those two things and by who plays audio. While nothing was played yet (or
/// another app took over), the keys go elsewhere (they may launch Music).
///
/// It is on while `HotkeyService.mediaKeys` is; turning it off removes the handlers and clears what was published.
@MainActor
final class SystemMediaControls {
    static let shared = SystemMediaControls(settings: .shared, playback: .shared)

    private let settings: HotkeyService
    private let playback: PlaybackState
    private var isOn = false
    /// Changes every time the controls are turned on, so that an observation left over from before ends.
    private var generation = 0
    private var commandTokens: [(command: MPRemoteCommand, token: Any)] = []

    /// What was published last, to publish again only when something is different.
    private struct Published: Equatable {
        var playing: Bool
        var artist: String
        var title: String
        var album: String
        var duration: Double
        var artwork: ObjectIdentifier?
    }

    private var published: Published?
    private var publishedElapsed: Double = 0
    private var publishedAt = Date()
    private var artwork: MPMediaItemArtwork?
    private var artworkSource: ObjectIdentifier?

    /// The seconds the position may be off from what the system extrapolates before it is published again
    /// (`PlaybackState.position` only moves in whole seconds, so it is up to a second behind).
    private static let driftTolerance = 2.5

    init(settings: HotkeyService, playback: PlaybackState) {
        self.settings = settings
        self.playback = playback
    }

    /// Follows the setting from now on.
    func start() {
        apply()
        observeSetting()
    }

    // MARK: - Setting

    private func observeSetting() {
        withObservationTracking {
            _ = settings.mediaKeys
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observeSetting()
            }
        }
    }

    private func apply() {
        settings.mediaKeys ? turnOn() : turnOff()
    }

    private func turnOn() {
        guard !isOn else { return }
        isOn = true
        generation += 1

        let center = MPRemoteCommandCenter.shared()
        let playback = self.playback
        let handlers: [(MPRemoteCommand, @MainActor @Sendable () -> Void)] = [
            (center.playCommand, { playback.resume() }),
            (center.pauseCommand, { playback.pause() }),
            (center.togglePlayPauseCommand, { playback.playPause() }),
            (center.nextTrackCommand, { playback.nextTrack() }),
            (center.previousTrackCommand, { playback.previousTrack() }),
        ]
        for (command, action) in handlers {
            command.isEnabled = true
            commandTokens.append((command, Self.addHandler(to: command, action)))
        }
        Log.info("media keys: handlers registered")

        publish()
        observePlayback(generation: generation)
    }

    private func turnOff() {
        guard isOn else { return }
        isOn = false

        for (command, token) in commandTokens {
            command.removeTarget(token)
            command.isEnabled = false
        }
        commandTokens = []
        clear()
        Log.info("media keys: handlers removed")
    }

    /// The handler runs on a queue of the system's choice, so it must not be isolated to the main actor itself
    /// (a closure made in an isolated method would be, and trap): it only hops there.
    nonisolated private static func addHandler(to command: MPRemoteCommand,
                                               _ action: @escaping @MainActor @Sendable () -> Void) -> Any {
        command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
    }

    // MARK: - Now playing

    private func observePlayback(generation: Int) {
        guard isOn, generation == self.generation else { return }
        withObservationTracking {
            _ = playback.status
            _ = playback.info
            _ = playback.duration
            _ = playback.artwork
            _ = playback.position
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isOn, generation == self.generation else { return }
                self.publish()
                self.observePlayback(generation: generation)
            }
        }
    }

    private func publish() {
        guard playback.status != .stopped, let info = playback.info else {
            clear()
            return
        }

        let playing = playback.status == .playing
        let image = playback.artwork
        let current = Published(playing: playing, artist: info.artist, title: info.title, album: info.album,
                                duration: playback.duration, artwork: image.map { ObjectIdentifier($0) })
        let now = Date()
        let expected = publishedElapsed + (published?.playing == true ? now.timeIntervalSince(publishedAt) : 0)
        let drifted = abs(playback.position - expected) > Self.driftTolerance
        guard current != published || drifted else { return }

        if let image {
            if artworkSource != ObjectIdentifier(image) {
                artwork = Self.makeArtwork(image)
                artworkSource = ObjectIdentifier(image)
            }
        } else {
            artwork = nil
            artworkSource = nil
        }

        var dictionary: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyAlbumTitle: info.album,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playback.position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if playback.duration > 0 { dictionary[MPMediaItemPropertyPlaybackDuration] = playback.duration }
        if let artwork { dictionary[MPMediaItemPropertyArtwork] = artwork }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = dictionary
        center.playbackState = playing ? .playing : .paused

        published = current
        publishedElapsed = playback.position
        publishedAt = now
    }

    /// Nothing plays (or the media keys are off): publishes nothing.
    private func clear() {
        guard published != nil || MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        published = nil
        artwork = nil
        artworkSource = nil
    }

    /// Made outside of the main actor's isolation for the same reason as the command handlers: the system asks for
    /// the image on its own queue.
    nonisolated private static func makeArtwork(_ image: CGImage) -> MPMediaItemArtwork {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return MPMediaItemArtwork(boundsSize: nsImage.size) { _ in nsImage }
    }
}
