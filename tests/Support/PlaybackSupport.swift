import Foundation
import Testing
@testable import iCanHazMusic

/// A sawtooth fixture of `prepare-fixtures.sh`: frame `n` of channel `c` is
/// `((n * (7 + 6c) + salt) mod 2^bits) / 2^(bits-1) - 1`, exactly representable as a Float, so what the engine
/// delivers can be compared with `==` against what the file holds. Different channels and different files have
/// different content, so a swapped channel, a wrong file or a shifted sample is always noticed.
struct RampFile {
    let name: String
    let sampleRate: Double
    let channels: Int
    let frames: Int
    let salt: Int
    let bits: Int

    func url() throws -> URL { try Fixtures.url("playback/" + name) }

    /// The same content stored under another name/container.
    func stored(as name: String) -> RampFile {
        RampFile(name: name, sampleRate: sampleRate, channels: channels, frames: frames, salt: salt, bits: bits)
    }

    var duration: Double { Double(frames) / sampleRate }

    func value(_ frame: Int, channel: Int) -> Float {
        let range = 1 << bits
        let k = (frame * (7 + 6 * channel) + salt) % range
        return Float(k) / Float(range / 2) - 1
    }

    /// What reaches the (stereo) output when the file is played at its own sample rate: mono is on both sides.
    func stereo(_ frame: Int, channel: Int) -> Float {
        value(frame, channel: channels == 1 ? 0 : channel)
    }

    static let a = RampFile(name: "a.flac", sampleRate: 44100, channels: 2, frames: 136_710, salt: 0, bits: 16)
    static let b = RampFile(name: "b.flac", sampleRate: 44100, channels: 2, frames: 110_250, salt: 5000, bits: 16)
    static let c = RampFile(name: "c.flac", sampleRate: 44100, channels: 2, frames: 88_200, salt: 9000, bits: 16)
    static let tiny = RampFile(name: "tiny.flac", sampleRate: 44100, channels: 2, frames: 2205, salt: 100, bits: 16)
    static let tiny2 = RampFile(name: "tiny2.flac", sampleRate: 44100, channels: 2, frames: 1500, salt: 200, bits: 16)
    static let r48 = RampFile(name: "r48.flac", sampleRate: 48000, channels: 2, frames: 96_000, salt: 300, bits: 16)
    static let r96 = RampFile(name: "r96_24.flac", sampleRate: 96000, channels: 2, frames: 192_000, salt: 400, bits: 24)
    static let mono22 = RampFile(name: "mono22.flac", sampleRate: 22050, channels: 1, frames: 33_075, salt: 500, bits: 16)
    static let surround = RampFile(name: "surround.flac", sampleRate: 44100, channels: 6, frames: 66_150, salt: 600, bits: 16)
}

/// A sine fixture: 1 kHz, amplitude 0.5 on the left and 0.25 on the right.
struct ToneFile {
    let name: String
    let sampleRate: Double
    let channels: Int
    let frames: Int

    static let frequency = 1000.0
    static let amplitude: [Double] = [0.5, 0.25]
    /// The biggest difference between two neighbouring samples of the loudest channel at `rate`.
    static func maxStep(rate: Double) -> Float {
        Float(2 * .pi * frequency * amplitude[0] / rate)
    }

    func url() throws -> URL { try Fixtures.url("playback/" + name) }
    var duration: Double { Double(frames) / sampleRate }

    /// The waveform at `seconds` into the file.
    static func value(at seconds: Double, channel: Int) -> Float {
        Float(amplitude[channel] * sin(2 * .pi * frequency * seconds))
    }

    static let sine44 = ToneFile(name: "sine44.flac", sampleRate: 44100, channels: 2, frames: 132_300)
    static let sine48 = ToneFile(name: "sine48.flac", sampleRate: 48000, channels: 2, frames: 96_000)
    static let sine32 = ToneFile(name: "sine32.flac", sampleRate: 32000, channels: 2, frames: 64_000)
    static let sine96 = ToneFile(name: "sine96_24.flac", sampleRate: 96000, channels: 2, frames: 192_000)
    static let sine22mono = ToneFile(name: "sine22_mono.flac", sampleRate: 22050, channels: 1, frames: 44_100)
}

// MARK: - Comparing audio

/// The largest absolute difference between `samples` (stereo, as delivered) and `expected(frame, channel)` over
/// `count` frames starting at `start`; `expected` gets the index relative to `start`.
///
/// Comparing outside the rendered audio is a failure of the test (`.infinity`), not a crash: a crash in the test
/// process takes minutes to report.
func maxDeviation(_ samples: [[Float]], from start: Int, count: Int, expected: (Int, Int) -> Float) -> Float {
    guard start >= 0, count >= 0, start + count <= samples[0].count else { return .infinity }
    var worst: Float = 0
    for channel in 0..<2 {
        for i in 0..<count {
            worst = max(worst, abs(samples[channel][start + i] - expected(i, channel)))
        }
    }
    return worst
}

/// The biggest jump between two neighbouring samples in `range` (both channels): a click is a big one.
func maxStep(_ samples: [[Float]], in range: Range<Int>) -> Float {
    var worst: Float = 0
    for channel in 0..<2 {
        for i in max(range.lowerBound, 1)..<min(range.upperBound, samples[channel].count) {
            worst = max(worst, abs(samples[channel][i] - samples[channel][i - 1]))
        }
    }
    return worst
}

func isSilent(_ samples: [[Float]], in range: Range<Int>) -> Bool {
    (0..<2).allSatisfy { channel in samples[channel][range].allSatisfy { $0 == 0 } }
}

func peak(_ samples: [[Float]], in range: Range<Int>) -> Float {
    (0..<2).map { channel in samples[channel][range].map(abs).max() ?? 0 }.max() ?? 0
}

extension Array where Element == [Float] {
    /// Appends rendered audio.
    mutating func append(_ other: [[Float]]) {
        if isEmpty { self = other; return }
        self[0] += other[0]
        self[1] += other[1]
    }

    var frameCount: Int { first?.count ?? 0 }
}
