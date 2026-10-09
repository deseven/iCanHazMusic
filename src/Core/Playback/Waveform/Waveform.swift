// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Everything the visual seek bar styles need to know about a track, made in one pass over the file
/// (`WaveformAnalyzer`) and stored as one record (`WaveformStore`), so that any style is shown at once from the cache and
/// switching styles never means analysing again.
///
/// - **Buckets**: the track is cut into `bucketCount` equal slices (fewer for a track of fewer frames; `rms.count` is the
///   truth, never assume `bucketCount`). `rms` and `peak` have one byte per bucket.
/// - **Encoding: dBFS, not linear.** `level = round(255 * clamp((dB - floor) / -floor))`. `rms`/`peak` are amplitudes
///   (`20 log10`, floor `floorDB` = -60 dB: 0 = silence, 255 = full scale); `bands` are powers (`10 log10` of the mean
///   square of the mono mix that falls into the band, floor `bandFloorDB` = -96 dB). Linear 8 bit would crush quiet
///   passages. The curves, floors and layout belong to the stored format: changing them means a new `formatVersion`
///   (which makes `WaveformStore` drop what it has).
/// - **Levels are absolute**, not normalised to the track; the renderers do that (`bars`, `peakBars`, `triBandBars`,
///   `spectrogram`).
/// - `rms`: RMS of both channels. `peak`: the largest sample of any channel. `bands`: `bandCount` log-spaced frequency
///   bands (`SpectralLayout`), one column per two buckets (`bandColumnCount`), column after column, lowest band first.
///   `structure`: where the sections of the track change and which sections sound alike.
struct Waveform: Equatable, Sendable {
    /// Buckets per track.
    static let bucketCount = 2048
    /// Frequency bands per column of `bands`.
    static let bandCount = 24
    /// Version of the encoding above and of the layout; the store drops entries of another one.
    static let formatVersion = 2
    /// Level of 0 in dBFS for `rms` and `peak`.
    static let floorDB = -60.0
    /// Level of 0 in dB for `bands`.
    static let bandFloorDB = -96.0
    /// The bands that make the low / mid / high groups of the tri-band view (about 40-1000 Hz, -3.4 kHz, -16 kHz).
    static let lowBands = 0..<13
    static let midBands = 13..<18
    static let highBands = 18..<24

    /// One byte per bucket: RMS level, 0 = silence (<= `floorDB`), 255 = 0 dBFS.
    let rms: [UInt8]
    /// One byte per bucket: peak level, same encoding as `rms`.
    let peak: [UInt8]
    /// `bandColumnCount` x `bandCount` bytes, see above.
    let bands: [UInt8]
    let structure: WaveformStructure

    /// `peak` defaults to `rms`, `bands` to silence (what tests that only care about one part want).
    init(rms: [UInt8], peak: [UInt8]? = nil, bands: [UInt8]? = nil, structure: WaveformStructure = .none) {
        self.rms = rms
        self.peak = peak ?? rms
        self.bands = bands ?? [UInt8](repeating: 0, count: Self.bandColumnCount(forBuckets: rms.count) * Self.bandCount)
        self.structure = structure
    }

    var isEmpty: Bool { rms.isEmpty }

    /// Columns of `bands` for a track of `buckets` buckets: two buckets share a column.
    static func bandColumnCount(forBuckets buckets: Int) -> Int {
        (buckets + 1) / 2
    }

    var bandColumnCount: Int { bands.count / Self.bandCount }

    /// The power (linear, mean square of the mono mix) in `band` of band column `column`; 0 outside.
    func bandPower(column: Int, band: Int) -> Double {
        guard (0..<bandColumnCount).contains(column), (0..<Self.bandCount).contains(band) else { return 0 }
        return Self.bandPowerTable[Int(bands[column * Self.bandCount + band])]
    }

    // MARK: Level encoding

    /// The level byte of an amplitude (RMS or peak; linear, 1 = full scale).
    static func level(forRMS rms: Double) -> UInt8 {
        guard rms > 0, rms.isFinite else { return rms == .infinity ? 255 : 0 }
        return encode(20 * log10(rms), floor: floorDB)
    }

    /// The amplitude (linear) a level byte stands for; 0 for silence.
    static func rms(forLevel level: UInt8) -> Double {
        level == 0 ? 0 : pow(10, (Double(level) / 255 * -floorDB + floorDB) / 20)
    }

    /// The level byte of a band's power (linear, mean square of the mono mix: 1 = a full scale square wave).
    static func bandLevel(forPower power: Double) -> UInt8 {
        guard power > 0, power.isFinite else { return power == .infinity ? 255 : 0 }
        return encode(10 * log10(power), floor: bandFloorDB)
    }

    private static func encode(_ db: Double, floor: Double) -> UInt8 {
        UInt8((255 * ((db - floor) / -floor).clamped(to: 0...1)).rounded())
    }

    /// Power (amplitude squared) per `rms`/`peak` level byte, for averaging.
    private static let power: [Double] = (0...255).map { level in
        let amplitude = rms(forLevel: UInt8(level))
        return amplitude * amplitude
    }

    /// Power per `bands` level byte; 0 for silence.
    private static let bandPowerTable: [Double] = (0...255).map { level in
        level == 0 ? 0 : pow(10, (Double(level) / 255 * -bandFloorDB + bandFloorDB) / 10)
    }

    /// The bucket-or-column range `0..<total` that item `index` of `count` covers: contiguous, never empty (with more
    /// items than `total` neighbours repeat).
    private static func range(of index: Int, count: Int, total: Int) -> Range<Int> {
        let start = index * total / count
        return start..<min(total, max(start + 1, (index + 1) * total / count))
    }

    // MARK: RMS

    /// The RMS envelope reduced to `count` columns, as the level of each (0...1, 1 = full scale, linear in dB: 0 is
    /// -60 dBFS or less). A column covers a contiguous run of buckets (always at least one, so with more columns
    /// than buckets neighbours repeat) and is their RMS: the levels are averaged in the power domain.
    func columns(_ count: Int) -> [Float] {
        let n = rms.count
        guard count > 0, n > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let range = Self.range(of: i, count: count, total: n)
            var sum = 0.0
            for j in range { sum += Self.power[Int(rms[j])] }
            let mean = sum / Double(range.count)
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

    // MARK: Peak + RMS

    /// Heights (0...1) of the two layers of the peak + RMS view.
    struct PeakBars: Equatable {
        var peak: [Float]
        var rms: [Float]
    }

    /// Both layers for `count` bars, as linear amplitude relative to the largest peak of the track (to the power of
    /// `exponent`), so the RMS bar is honestly a fraction of the peak bar. A column's peak is the largest peak of its
    /// buckets, its RMS their power average. All zero for a silent track.
    func peakBars(_ count: Int, exponent: Double = 1) -> PeakBars {
        let n = rms.count
        guard count > 0, n > 0, peak.count == n, exponent > 0 else { return PeakBars(peak: [], rms: []) }
        var peaks = [Double](repeating: 0, count: count)
        var means = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let range = Self.range(of: i, count: count, total: n)
            var largest: UInt8 = 0
            var sum = 0.0
            for j in range {
                largest = max(largest, peak[j])
                sum += Self.power[Int(rms[j])]
            }
            peaks[i] = Self.rms(forLevel: largest)
            means[i] = (sum / Double(range.count)).squareRoot()
        }
        guard let top = peaks.max(), top > 0 else {
            return PeakBars(peak: [Float](repeating: 0, count: count), rms: [Float](repeating: 0, count: count))
        }
        func shape(_ value: Double) -> Float { Float(pow(min(1, value / top), exponent)) }
        return PeakBars(peak: peaks.map(shape), rms: means.map(shape))
    }

    // MARK: Bands

    /// Heights (0...1) of the three nested layers of the tri-band view; each is the sum of its band group and
    /// everything above it, so `all >= upper >= high`.
    struct TriBandBars: Equatable {
        /// Low + mid + high.
        var all: [Float]
        /// Mid + high.
        var upper: [Float]
        var high: [Float]
    }

    /// The three layers for `count` bars. The amplitude of a group is the square root of its mean power in the column's
    /// stretch of the track; the sums are relative to the loudest column (all three layers share the scale, so they add
    /// up to the loudness) and raised to `exponent`. All zero for a silent track.
    func triBandBars(_ count: Int, exponent: Double = 0.6) -> TriBandBars {
        let columns = bandColumnCount
        guard count > 0, columns > 0, exponent > 0 else { return TriBandBars(all: [], upper: [], high: []) }
        var low = [Double](repeating: 0, count: count)
        var mid = low
        var high = low
        for i in 0..<count {
            let range = Self.range(of: i, count: count, total: columns)
            var sums = (low: 0.0, mid: 0.0, high: 0.0)
            for column in range {
                let base = column * Self.bandCount
                for band in Self.lowBands { sums.low += Self.bandPowerTable[Int(bands[base + band])] }
                for band in Self.midBands { sums.mid += Self.bandPowerTable[Int(bands[base + band])] }
                for band in Self.highBands { sums.high += Self.bandPowerTable[Int(bands[base + band])] }
            }
            let divisor = Double(range.count)
            low[i] = (sums.low / divisor).squareRoot()
            mid[i] = (sums.mid / divisor).squareRoot()
            high[i] = (sums.high / divisor).squareRoot()
        }
        let top = (0..<count).map { low[$0] + mid[$0] + high[$0] }.max() ?? 0
        guard top > 0 else {
            let zeros = [Float](repeating: 0, count: count)
            return TriBandBars(all: zeros, upper: zeros, high: zeros)
        }
        func shape(_ value: Double) -> Float { Float(pow(min(1, value / top), exponent)) }
        return TriBandBars(all: (0..<count).map { shape(low[$0] + mid[$0] + high[$0]) },
                           upper: (0..<count).map { shape(mid[$0] + high[$0]) },
                           high: high.map(shape))
    }

    /// The spectrogram for `count` columns: intensity (0...255) of each cell, `count` x `bandCount`, column after column,
    /// lowest band first. Every band has the track's own average subtracted (in dB, "whitened": otherwise the bass
    /// would be bright and the treble black on all music), then the range between the 5th and the 99.5th percentile
    /// of the track is stretched over 0...255. Empty for a track without bands.
    func spectrogram(columns count: Int) -> [UInt8] {
        let stored = bandColumnCount
        guard count > 0, stored > 0 else { return [] }
        let bandCount = Self.bandCount
        let dbPerLevel = -Self.bandFloorDB / 255

        var means = [Double](repeating: 0, count: bandCount)
        for column in 0..<stored {
            for band in 0..<bandCount { means[band] += Double(bands[column * bandCount + band]) * dbPerLevel }
        }
        for band in 0..<bandCount { means[band] /= Double(stored) }

        // In dB relative to the band's mean, the same shape as `bands`.
        var whitened = [Float](repeating: 0, count: bands.count)
        for column in 0..<stored {
            for band in 0..<bandCount {
                whitened[column * bandCount + band] = Float(Double(bands[column * bandCount + band]) * dbPerLevel - means[band])
            }
        }
        let sorted = whitened.sorted()
        func percentile(_ p: Double) -> Float { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let low = percentile(0.05)
        let high = max(percentile(0.995), low + 1e-3)

        var result = [UInt8](repeating: 0, count: count * bandCount)
        for i in 0..<count {
            let range = Self.range(of: i, count: count, total: stored)
            for band in 0..<bandCount {
                var sum: Float = 0
                for column in range { sum += whitened[column * bandCount + band] }
                let value = ((sum / Float(range.count) - low) / (high - low)).clamped(to: 0...1)
                result[i * bandCount + band] = UInt8((value * 255).rounded())
            }
        }
        return result
    }

    // MARK: Structure

    /// The section (index into the sections of the track, by sound: equal labels sound alike) of each of `count`
    /// columns.
    func segmentLabels(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let n = max(rms.count, 1)
        var segment = 0
        return (0..<count).map { i in
            // The bucket at the start of the column.
            let bucket = i * n / count
            while segment < structure.boundaries.count, structure.boundaries[segment] <= bucket { segment += 1 }
            return structure.labels[min(segment, structure.labels.count - 1)]
        }
    }

    /// Where the sections change, as fractions of the track (0...1, ascending).
    var boundaryFractions: [Double] {
        let n = Double(max(rms.count, 1))
        return structure.boundaries.map { Double($0) / n }
    }

    // MARK: Storage

    /// The record as stored: `UInt16` bucket count, `UInt16` section count, `rms`, `peak`, `bands`, the section
    /// boundaries (`UInt16` each, one less than sections), the section labels (a byte each). Little endian.
    func encoded() -> Data {
        var data = Data()
        data.reserveCapacity(4 + rms.count + peak.count + bands.count + 3 * structure.labels.count)
        func append(_ value: Int) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        append(rms.count)
        append(structure.labels.count)
        data.append(contentsOf: rms)
        data.append(contentsOf: peak)
        data.append(contentsOf: bands)
        for boundary in structure.boundaries { append(boundary) }
        for label in structure.labels { data.append(UInt8(min(label, 255))) }
        return data
    }

    /// The record from `encoded()`; nil if it isn't one (wrong size, boundaries out of order, ...).
    init?(encoded data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let n = Int(bytes[0]) | Int(bytes[1]) << 8
        let sections = Int(bytes[2]) | Int(bytes[3]) << 8
        guard (1...Self.bucketCount).contains(n), sections >= 1 else { return nil }
        let bandBytes = Self.bandColumnCount(forBuckets: n) * Self.bandCount
        guard bytes.count == 4 + 2 * n + bandBytes + 2 * (sections - 1) + sections else { return nil }

        var offset = 4
        func take(_ count: Int) -> [UInt8] {
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }
        let rms = take(n)
        let peak = take(n)
        let bands = take(bandBytes)
        let boundaries = (0..<(sections - 1)).map { _ -> Int in
            defer { offset += 2 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        let labels = take(sections).map { Int($0) }
        var previous = 0
        for boundary in boundaries {
            guard boundary > previous, boundary < n else { return nil }
            previous = boundary
        }
        self.init(rms: rms, peak: peak, bands: bands, structure: WaveformStructure(boundaries: boundaries, labels: labels))
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
