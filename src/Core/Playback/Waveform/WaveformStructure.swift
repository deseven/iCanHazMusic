// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The sections of a track (intro, verse, chorus, ...) as far as they can be told from the sound.
struct WaveformStructure: Equatable, Sendable {
    /// Buckets (of `Waveform.rms`) where a new section starts, ascending, without the 0 the first one starts at.
    let boundaries: [Int]
    /// One label per section (`boundaries.count + 1`): sections with the same label sound alike. Labels are numbered
    /// in order of first appearance, from 0.
    let labels: [Int]

    /// One section, no boundaries.
    static let none = WaveformStructure(boundaries: [], labels: [0])

    init(boundaries: [Int], labels: [Int]) {
        self.boundaries = boundaries
        self.labels = labels.count == boundaries.count + 1 ? labels : [Int](repeating: 0, count: boundaries.count + 1)
    }
}

/// Finds the sections of a track: the track is reduced to about one feature vector per second (loudness, a cepstrum-like
/// summary of the band profile for the timbre, the pitch classes for the harmony), the vectors are compared with each
/// other (a self-similarity matrix), the places where "before" and "after" differ most while each side is
/// self-similar are the boundaries (a checkerboard kernel, Foote's novelty), and the sections are grouped into labels
/// by the similarity of their average vector.
///
/// Pure function of its input (no I/O), cheap (the matrix is at most 600 x 600).
enum WaveformStructureAnalyzer {
    /// Frames the track is reduced to: one per second, between these.
    static let minFrames = 48
    static let maxFrames = 600
    /// Tracks shorter than this have no sections.
    static let minSeconds = 20.0
    /// Features are scaled to unit deviation, but never by less than this (they are dB and strengths of 0...1).
    static let minDeviation: Float = 0.01
    /// Sections whose average vectors are at least this similar (cosine) get the same label.
    static let sameLabelSimilarity: Float = 0.8

    /// - Parameters:
    ///   - rmsDB: loudness per bucket (dB, any reference).
    ///   - bandDB: `bands` values per bucket, band after band (dB of the power in each band).
    ///   - chroma: 12 pitch class strengths per bucket (any scale; only the shape within a bucket matters).
    ///   - seconds: length of the track.
    static func analyse(rmsDB: [Float], bandDB: [Float], bands: Int, chroma: [Float], seconds: Double) -> WaveformStructure {
        let n = rmsDB.count
        let frames = max(minFrames, min(maxFrames, Int(seconds)))
        guard seconds >= minSeconds, n >= frames, bandDB.count == n * bands, chroma.count == n * 12, bands > 0 else { return .none }

        let dims = 1 + 12 + 12
        var features = reducedFeatures(rmsDB: rmsDB, bandDB: bandDB, bands: bands, chroma: chroma, frames: frames, dims: dims)

        // z-score per dimension; the pitch classes count less
        for j in 0..<dims {
            var mean: Float = 0
            for m in 0..<frames { mean += features[m * dims + j] }
            mean /= Float(frames)
            var variance: Float = 0
            for m in 0..<frames { variance += (features[m * dims + j] - mean) * (features[m * dims + j] - mean) }
            // A dimension that hardly varies (silence, one note) stays flat instead of being blown up to noise.
            let deviation = max((variance / Float(frames)).squareRoot(), minDeviation)
            let weight: Float = j >= 13 ? 0.7 : 1
            for m in 0..<frames { features[m * dims + j] = (features[m * dims + j] - mean) / deviation * weight }
        }

        // smooth over 3 frames, then unit length
        var unit = [Float](repeating: 0, count: frames * dims)
        for m in 0..<frames {
            let lo = max(0, m - 1), hi = min(frames - 1, m + 1)
            var norm: Float = 0
            for j in 0..<dims {
                var sum: Float = 0
                for q in lo...hi { sum += features[q * dims + j] }
                let value = sum / Float(hi - lo + 1)
                unit[m * dims + j] = value
                norm += value * value
            }
            let scale = 1 / max(1e-6, norm.squareRoot())
            for j in 0..<dims { unit[m * dims + j] *= scale }
        }

        var similarity = [Float](repeating: 0, count: frames * frames)
        for i in 0..<frames {
            for j in i..<frames {
                var sum: Float = 0
                for k in 0..<dims { sum += unit[i * dims + k] * unit[j * dims + k] }
                similarity[i * frames + j] = sum
                similarity[j * frames + i] = sum
            }
        }

        let novelty = checkerboardNovelty(similarity, frames: frames, seconds: seconds)
        let cuts = peaks(of: novelty, frames: frames, seconds: seconds)
        let labels = cluster(unit: unit, frames: frames, dims: dims, cuts: cuts)

        // Frames to buckets; boundaries that land on the same bucket (or on 0) would be empty sections.
        var boundaries: [Int] = []
        var keptLabels = [labels[0]]
        for (index, cut) in cuts.enumerated() {
            let bucket = cut * n / frames
            guard bucket > (boundaries.last ?? 0), bucket < n else { continue }
            boundaries.append(bucket)
            keptLabels.append(labels[index + 1])
        }
        return WaveformStructure(boundaries: boundaries, labels: relabelled(keptLabels))
    }

    /// Average feature vector per frame: the loudness, the cosine transform of the band profile (a cepstrum, 12
    /// coefficients), the pitch classes (largest one = 1).
    private static func reducedFeatures(rmsDB: [Float], bandDB: [Float], bands: Int, chroma: [Float],
                                        frames: Int, dims: Int) -> [Float] {
        let n = rmsDB.count
        var cosines = [Float](repeating: 0, count: 12 * bands)
        for k in 1...12 {
            for b in 0..<bands { cosines[(k - 1) * bands + b] = cosf(Float.pi * Float(k) * (Float(b) + 0.5) / Float(bands)) }
        }
        var features = [Float](repeating: 0, count: frames * dims)
        var counts = [Float](repeating: 0, count: frames)
        for i in 0..<n {
            let m = min(frames - 1, i * frames / n)
            features[m * dims] += rmsDB[i]
            for k in 0..<12 {
                var sum: Float = 0
                for b in 0..<bands { sum += bandDB[i * bands + b] * cosines[k * bands + b] }
                features[m * dims + 1 + k] += sum
            }
            var largest: Float = 0
            for k in 0..<12 { largest = max(largest, chroma[i * 12 + k]) }
            if largest > 0 {
                for k in 0..<12 { features[m * dims + 13 + k] += chroma[i * 12 + k] / largest * 0.7 }
            }
            counts[m] += 1
        }
        for m in 0..<frames where counts[m] > 0 {
            for j in 0..<dims { features[m * dims + j] /= counts[m] }
        }
        return features
    }

    /// How much each frame is a change from what is before to what is after (0...1).
    private static func checkerboardNovelty(_ similarity: [Float], frames: Int, seconds: Double) -> [Float] {
        let half = max(4, min(16, Int((8 * Double(frames) / seconds).rounded())))
        var novelty = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for a in -half..<half {
                for b in -half..<half {
                    let x = i + a, y = i + b
                    guard x >= 0, x < frames, y >= 0, y < frames else { continue }
                    let sign: Float = ((a < 0) == (b < 0)) ? 1 : -1
                    let gauss = expf(-0.5 * (powf(Float(a) + 0.5, 2) + powf(Float(b) + 0.5, 2)) / powf(Float(half) * 0.5, 2))
                    sum += sign * gauss * similarity[x * frames + y]
                }
            }
            novelty[i] = sum
        }
        let largest = max(novelty.max() ?? 1, 1e-6)
        return novelty.map { max(0, $0) / largest }
    }

    /// The frames where a new section starts: local maxima of the novelty that stand out, kept apart from each other.
    private static func peaks(of novelty: [Float], frames: Int, seconds: Double) -> [Int] {
        let mean = novelty.reduce(0, +) / Float(frames)
        let deviation = (novelty.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(frames)).squareRoot()
        let minDistance = max(3, Int(Double(frames) * 14 / seconds))
        var candidates: [Int] = []
        for i in 1..<(frames - 1) {
            guard novelty[i] > mean + deviation, novelty[i] > 0.25,
                  i >= minDistance / 2, i <= frames - minDistance / 2 else { continue }
            let window = max(0, i - minDistance)...min(frames - 1, i + minDistance)
            if window.allSatisfy({ novelty[$0] <= novelty[i] }) { candidates.append(i) }
        }
        // The strongest first, each at least `minDistance` from the ones kept.
        var kept: [Int] = []
        for candidate in candidates.sorted(by: { novelty[$0] > novelty[$1] })
        where !kept.contains(where: { abs($0 - candidate) < minDistance }) {
            kept.append(candidate)
        }
        return kept.sorted()
    }

    /// A label per section (`cuts.count + 1`): greedy, a section joins the first earlier group it resembles.
    private static func cluster(unit: [Float], frames: Int, dims: Int, cuts: [Int]) -> [Int] {
        let starts = [0] + cuts
        let ends = cuts + [frames]
        var centroids: [[Float]] = []
        var labels: [Int] = []
        for s in 0..<starts.count {
            var vector = [Float](repeating: 0, count: dims)
            for m in starts[s]..<ends[s] { for j in 0..<dims { vector[j] += unit[m * dims + j] } }
            let norm = max(1e-6, vector.reduce(0) { $0 + $1 * $1 }.squareRoot())
            vector = vector.map { $0 / norm }
            var found = -1
            var best = sameLabelSimilarity
            for (index, centroid) in centroids.enumerated() {
                var sum: Float = 0
                for j in 0..<dims { sum += vector[j] * centroid[j] }
                if sum > best { best = sum; found = index }
            }
            if found < 0 {
                centroids.append(vector)
                labels.append(centroids.count - 1)
            } else {
                labels.append(found)
            }
        }
        return labels
    }

    /// Labels renumbered in order of first appearance (a dropped section may have taken a label with it).
    private static func relabelled(_ labels: [Int]) -> [Int] {
        var map: [Int: Int] = [:]
        return labels.map { label in
            if let known = map[label] { return known }
            map[label] = map.count
            return map.count - 1
        }
    }
}
