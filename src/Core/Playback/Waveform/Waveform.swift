// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The loudness envelope of a track: one RMS level per slice of the track (a *bucket*), `bucketCount` of them
/// whatever the length (fewer for a track of fewer frames).
///
/// - **Encoding: dBFS, not linear.** A byte per bucket, `level = round(255 * clamp((dB + 60) / 60))` with
///   `dB = 20 log10(rms)`: 60 dB of range in 0.24 dB steps, 0 = silence (-60 dBFS or less, digital zero included),
///   255 = full scale. Linear 8 bit would crush quiet passages. The curve and the floor belong to the stored format:
///   changing them means a new `formatVersion` (which makes `WaveformStore` drop what it has).
/// - The level is *absolute*, not normalised to the track; the renderer does that (`bars`).
/// - `levels.count` is the truth, never assume `bucketCount`.
struct Waveform: Equatable, Sendable {
    /// Buckets per track.
    static let bucketCount = 2048
    /// Version of the encoding above and of `bucketCount`; the store drops entries of another one.
    static let formatVersion = 1
    /// Level of 0 in dBFS.
    static let floorDB = -60.0

    /// One byte per bucket: RMS level, 0 = silence (<= `floorDB`), 255 = 0 dBFS.
    let levels: [UInt8]

    init(levels: [UInt8]) {
        self.levels = levels
    }

    // MARK: Encoding

    /// The level byte of an RMS value (linear, 1 = full scale).
    static func level(forRMS rms: Double) -> UInt8 {
        guard rms > 0, rms.isFinite else { return rms == .infinity ? 255 : 0 }
        let db = 20 * log10(rms)
        let scaled = ((db - floorDB) / -floorDB).clamped(to: 0...1)
        return UInt8((255 * scaled).rounded())
    }

    /// The RMS value (linear) a level byte stands for; 0 for silence.
    static func rms(forLevel level: UInt8) -> Double {
        level == 0 ? 0 : pow(10, (Double(level) / 255 * -floorDB + floorDB) / 20)
    }

    /// Power (RMS squared) per level byte, for averaging.
    private static let power: [Double] = (0...255).map { level in
        let rms = rms(forLevel: UInt8(level))
        return rms * rms
    }

    // MARK: Reduction

    /// The envelope reduced to `count` columns, as the level of each (0...1, 1 = full scale, linear in dB: 0 is
    /// -60 dBFS or less). A column covers a contiguous run of buckets (always at least one, so with more columns
    /// than buckets neighbours repeat) and is their RMS: the levels are averaged in the power domain.
    func columns(_ count: Int) -> [Float] {
        let n = levels.count
        guard count > 0, n > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let start = i * n / count
            let end = min(n, max(start + 1, (i + 1) * n / count))
            var sum = 0.0
            for j in start..<end { sum += Self.power[Int(levels[j])] }
            let mean = sum / Double(end - start)
            guard mean > 0 else { continue }
            let db = 10 * log10(mean)
            result[i] = Float(((db - Self.floorDB) / -Self.floorDB).clamped(to: 0...1))
        }
        return result
    }

    /// Bar heights (0...1) for `count` bars: the loudest column is 1, the others are their amplitude relative to it
    /// raised to `exponent` (1 = plain linear amplitude, what most waveform displays draw; smaller values lift the
    /// quiet parts; a height linear in dB, which looks "all tall", is the limit towards 0). What is more than
    /// `rangeDB` below the loudest column is 0. All zero for a silent track.
    func bars(_ count: Int, rangeDB: Double, exponent: Double = 1) -> [Float] {
        let columns = columns(count)
        guard let loudest = columns.max(), loudest > 0, rangeDB > 0, exponent > 0 else {
            return [Float](repeating: 0, count: columns.count)
        }
        // Columns are 0...1 over `-floorDB` dB.
        let dbPerUnit = -Self.floorDB
        return columns.map { column in
            let belowDB = Double(loudest - column) * dbPerUnit
            guard column > 0, belowDB < rangeDB else { return 0 }
            return Float(pow(10, -belowDB / 20 * exponent))
        }
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
