import Foundation
import Observation

/// Fake playback state so the UI can be exercised without an audio engine.
@Observable
final class PlaybackState {
    var isPlaying = false
    var position: Double = 83
    var duration: Double = 412
    var volume: Double = 0.7

    let artist = "Boards of Canada"
    let track = "Roygbiv"
    let album = "Music Has the Right to Children"
    let year = "1998"
    let codec = "FLAC · 44.1 kHz · 16 bit · 923 kbps"

    func togglePlay() { isPlaying.toggle() }

    func stop() {
        isPlaying = false
        position = 0
    }

    func tick() {
        guard isPlaying else { return }
        position += 1
        if position >= duration { stop() }
    }
}
