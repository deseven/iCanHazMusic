// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SQLite3
import Testing
@testable import iCanHazMusic

extension AllTests {
    // MARK: - Model

    @MainActor @Suite("Waveform: model")
    struct WaveformModelTests {
        @Test("silence is 0, full scale is 255, -60 dBFS and below are 0, in between is linear in dB")
        func encoding() {
            #expect(Waveform.level(forRMS: 0) == 0)
            #expect(Waveform.level(forRMS: 1) == 255)
            #expect(Waveform.level(forRMS: 10) == 255)
            #expect(Waveform.level(forRMS: 0.001) == 0)
            #expect(Waveform.level(forRMS: 0.00001) == 0)
            #expect(Waveform.level(forRMS: .nan) == 0)
            #expect(Waveform.level(forRMS: -1) == 0)
            // -20 dB = a third of the way up from -60
            #expect(Waveform.level(forRMS: 0.1) == 170)
            // -6.02 dB
            #expect(Waveform.level(forRMS: 0.5) == 229)
        }

        @Test("a level goes back to the same level through its RMS value")
        func roundTrip() {
            for level in 1...255 {
                let rms = Waveform.rms(forLevel: UInt8(level))
                #expect(Waveform.level(forRMS: rms) == UInt8(level))
            }
            #expect(Waveform.rms(forLevel: 0) == 0)
            #expect(abs(Waveform.rms(forLevel: 255) - 1) < 1e-12)
        }

        @Test("more columns than buckets repeat the buckets")
        func moreColumnsThanBuckets() {
            let waveform = Waveform(rms: [0, 255])
            #expect(waveform.columns(4) == [0, 0, 1, 1])
            #expect(waveform.columns(2) == [0, 1])
        }

        @Test("one column is the RMS of everything: levels are averaged as power")
        func oneColumn() {
            #expect(Waveform(rms: [255, 255, 255]).columns(1) == [1])
            // half the power = -3 dB = 57/60
            let half = Waveform(rms: [0, 255]).columns(1)[0]
            #expect(abs(half - 57.0 / 60.0) < 0.001)
            #expect(Waveform(rms: [0, 0, 0]).columns(1) == [0])
        }

        @Test("group sizes that don't divide the bucket count lose nothing and repeat nothing")
        func uneven() {
            let waveform = Waveform(rms: [UInt8](repeating: 200, count: Waveform.bucketCount))
            for count in [1, 7, 100, 333, 1000, 2047, 2048, 5000] {
                let columns = waveform.columns(count)
                #expect(columns.count == count)
                #expect(columns.allSatisfy { abs($0 - 200.0 / 255.0) < 0.001 }, "count \(count)")
            }
            // Every bucket belongs to a column: a single loud one shows up whatever the grouping.
            var levels = [UInt8](repeating: 0, count: Waveform.bucketCount)
            levels[1500] = 255
            for count in [10, 100, 333, 1000] {
                #expect(Waveform(rms: levels).columns(count).filter { $0 > 0 }.count == 1, "count \(count)")
            }
        }

        @Test("nothing to reduce, nothing to draw")
        func empty() {
            #expect(Waveform(rms: []).columns(10).isEmpty)
            #expect(Waveform(rms: [1, 2]).columns(0).isEmpty)
            #expect(Waveform(rms: [1, 2]).columns(-3).isEmpty)
        }

        @Test("bars: the loudest column is full height, the others are their relative amplitude to the exponent, quieter than the range is 0")
        func bars() {
            // 255 = 0 dB, 170 = -20 dB, 85 = -40 dB, 0 = silence
            let waveform = Waveform(rms: [255, 170, 85, 0])
            let linear = waveform.bars(4, rangeDB: 30)
            #expect(linear[0] == 1)
            #expect(abs(linear[1] - 0.1) < 0.005)   // -20 dB = amplitude 0.1
            #expect(linear[2] == 0)                  // beyond the range
            #expect(linear[3] == 0)
            // A smaller exponent lifts the quiet parts: 0.1^0.5
            let lifted = waveform.bars(4, rangeDB: 30, exponent: 0.5)
            #expect(abs(lifted[1] - 0.316) < 0.005)
            // Relative to the loudest, not to full scale.
            let quiet = Waveform(rms: [170, 85]).bars(2, rangeDB: 40)
            #expect(quiet[0] == 1)
            #expect(abs(quiet[1] - 0.1) < 0.005)
        }

        @Test("bars: a passage 12 dB quieter is clearly shorter, not nearly as tall as the loud one")
        func barsContrast() {
            // 255 = 0 dB, 204 = -12 dB
            let bars = Waveform(rms: [255, 204]).bars(2, rangeDB: 48, exponent: 0.6)
            #expect(bars[0] == 1)
            #expect(bars[1] < 0.5)
            #expect(bars[1] > 0.35)
        }

        @Test("a silent track has bars of height 0")
        func silentBars() {
            #expect(Waveform(rms: [0, 0, 0, 0]).bars(3, rangeDB: 40) == [0, 0, 0])
        }

        @Test("peak + RMS: both layers are linear amplitude relative to the largest peak; a column's peak is its largest")
        func peakBars() {
            // 255 = 1, 170 = 0.1, 85 = 0.01
            let waveform = Waveform(rms: [85, 170], peak: [170, 255])
            let bars = waveform.peakBars(2)
            #expect(abs(bars.peak[0] - 0.1) < 0.005)
            #expect(bars.peak[1] == 1)
            #expect(abs(bars.rms[0] - 0.01) < 0.001)
            #expect(abs(bars.rms[1] - 0.1) < 0.005)

            // One column over both buckets: the larger peak, the power average of the RMS.
            let one = waveform.peakBars(1)
            #expect(one.peak == [1])
            #expect(abs(one.rms[0] - (0.5 * (0.01 * 0.01 + 0.1 * 0.1)).squareRoot()) < 0.002)

            let flat = waveform.peakBars(2, exponent: 0.5)
            #expect(abs(flat.peak[0] - 0.316) < 0.005)

            #expect(Waveform(rms: [0, 0], peak: [0, 0]).peakBars(3) == Waveform.PeakBars(peak: [0, 0, 0], rms: [0, 0, 0]))
            #expect(Waveform(rms: []).peakBars(3).peak.isEmpty)
        }

        /// A waveform of `columns` band columns (two buckets each) with the given band levels per column.
        private func banded(_ columns: [[Int: UInt8]]) -> Waveform {
            var bands = [UInt8](repeating: 0, count: columns.count * Waveform.bandCount)
            for (c, levels) in columns.enumerated() { for (band, level) in levels { bands[c * Waveform.bandCount + band] = level } }
            return Waveform(rms: [UInt8](repeating: 100, count: columns.count * 2), bands: bands)
        }

        @Test("tri-band: the layers are nested sums of the groups and share the scale of the loudest column")
        func triBandBars() {
            // 255 = power 1, 255 - 53 = -20 dB = power 0.01 (amplitude 0.1)
            let low = Waveform.lowBands.lowerBound, mid = Waveform.midBands.lowerBound, high = Waveform.highBands.lowerBound
            let waveform = banded([[low: 255], [high: 255], [low: 255, mid: 255, high: 255], [:]])
            let bars = waveform.triBandBars(4, exponent: 1)
            // column 0: only low (amplitude 1); column 1: only high (1); column 2: 1 + 1 + 1 = 3 = the loudest
            #expect(abs(bars.all[0] - 1.0 / 3) < 0.001 && bars.upper[0] == 0 && bars.high[0] == 0)
            #expect(abs(bars.all[1] - 1.0 / 3) < 0.001 && abs(bars.upper[1] - 1.0 / 3) < 0.001 && abs(bars.high[1] - 1.0 / 3) < 0.001)
            #expect(abs(bars.all[2] - 1) < 0.001 && abs(bars.upper[2] - 2.0 / 3) < 0.001 && abs(bars.high[2] - 1.0 / 3) < 0.001)
            #expect(bars.all[3] == 0 && bars.upper[3] == 0 && bars.high[3] == 0)
            for i in 0..<4 { #expect(bars.all[i] >= bars.upper[i] && bars.upper[i] >= bars.high[i]) }

            // The exponent lifts the quiet ones.
            #expect(abs(waveform.triBandBars(4, exponent: 0.5).all[0] - (1.0 / 3).squareRoot()) < 0.001)
            // Silence, and nothing.
            #expect(banded([[:], [:]]).triBandBars(2).all == [0, 0])
            #expect(Waveform(rms: []).triBandBars(2).all.isEmpty)
        }

        @Test("spectrogram: every band is whitened (its own average is zero), the brightest cell is full")
        func spectrogram() {
            // Whatever its level, a band that never changes is the same dark everywhere: no bass-is-bright.
            let flat = banded((0..<50).map { _ in [0: 200, 5: 120, 20: 60] })
            #expect(flat.spectrogram(columns: 30).allSatisfy { $0 == 0 })
            #expect(flat.spectrogram(columns: 30).count == 30 * Waveform.bandCount)

            var columns = (0..<100).map { _ in [Int: UInt8]() }
            columns[50] = [5: 200]
            let bright = banded(columns).spectrogram(columns: 100)
            #expect(bright[50 * Waveform.bandCount + 5] == 255)
            #expect(bright[10 * Waveform.bandCount + 5] == 0)

            // A rising band gets brighter along the way.
            let ramp = banded((0..<100).map { [3: UInt8(50 + $0)] }).spectrogram(columns: 100)
            let line = (0..<100).map { ramp[$0 * Waveform.bandCount + 3] }
            #expect(zip(line, line.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(line[0] == 0 && line[99] == 255)

            #expect(Waveform(rms: []).spectrogram(columns: 10).isEmpty)
        }

        @Test("sections: each column gets the label of the section it starts in; the boundaries are fractions of the track")
        func sections() {
            let structure = WaveformStructure(boundaries: [30, 60], labels: [0, 1, 0])
            let waveform = Waveform(rms: [UInt8](repeating: 1, count: 100), structure: structure)
            #expect(waveform.segmentLabels(10) == [0, 0, 0, 1, 1, 1, 0, 0, 0, 0])
            #expect(waveform.boundaryFractions == [0.3, 0.6])
            #expect(Waveform(rms: [1, 2, 3]).segmentLabels(3) == [0, 0, 0])
            #expect(Waveform(rms: [1, 2, 3]).boundaryFractions.isEmpty)
            // A structure whose labels don't match its boundaries becomes one label per section.
            #expect(WaveformStructure(boundaries: [5], labels: [0]).labels == [0, 0])
        }

        @Test("the record survives encoding, and what isn't one is refused")
        func recordRoundTrip() throws {
            let rms = (0..<300).map { UInt8($0 % 256) }
            let bands = (0..<150 * Waveform.bandCount).map { UInt8(($0 * 31) % 256) }
            let waveform = Waveform(rms: rms, peak: rms.reversed(), bands: bands,
                                    structure: WaveformStructure(boundaries: [10, 120, 299], labels: [0, 1, 2, 1]))
            #expect(Waveform(encoded: waveform.encoded()) == waveform)
            #expect(Waveform(encoded: Waveform(rms: [5]).encoded()) == Waveform(rms: [5]))

            let data = waveform.encoded()
            #expect(Waveform(encoded: data.dropLast()) == nil)
            #expect(Waveform(encoded: data + [0]) == nil)
            #expect(Waveform(encoded: Data()) == nil)
            #expect(Waveform(encoded: Data([1, 2, 3])) == nil)
            #expect(Waveform(encoded: Data(repeating: 0, count: 100)) == nil)
            // Boundaries that don't ascend or leave the track.
            #expect(Waveform(encoded: record(withBoundaries: [50, 20], buckets: 100)) == nil)
            #expect(Waveform(encoded: record(withBoundaries: [20, 100], buckets: 100)) == nil)
            #expect(Waveform(encoded: record(withBoundaries: [20, 50], buckets: 100)) != nil)
        }

        /// The record of a track with the given section boundaries, which `Waveform` itself would not let one write.
        private func record(withBoundaries boundaries: [Int], buckets: Int) -> Data {
            var data = Waveform(rms: [UInt8](repeating: 1, count: buckets),
                                structure: WaveformStructure(boundaries: Array(1...boundaries.count),
                                                             labels: Array(repeating: 0, count: boundaries.count + 1))).encoded()
            let at = 4 + 2 * buckets + Waveform.bandColumnCount(forBuckets: buckets) * Waveform.bandCount
            for (i, boundary) in boundaries.enumerated() {
                data[at + 2 * i] = UInt8(boundary & 0xff)
                data[at + 2 * i + 1] = UInt8(boundary >> 8)
            }
            return data
        }
    }

    // MARK: - Store

    @MainActor @Suite("Waveform: store")
    struct WaveformStoreTests {
        private func levels(_ seed: Int, count: Int = Waveform.bucketCount) -> Waveform {
            let rms = (0..<count).map { UInt8(($0 * 7 + seed) % 256) }
            let bands = (0..<Waveform.bandColumnCount(forBuckets: count) * Waveform.bandCount).map { UInt8(($0 * 13 + seed) % 256) }
            let structure = count > 100
                ? WaveformStructure(boundaries: [40, 90], labels: [0, 1, 0])
                : WaveformStructure.none
            return Waveform(rms: rms, peak: rms.map { $0 / 2 + 100 }, bands: bands, structure: structure)
        }

        @Test("a waveform comes back as stored, also from a new store over the same file")
        func roundTrip() throws {
            let dir = try TempDir()
            let url = dir.path(".cache/waveforms.sqlite")
            let store = WaveformStore(url: url)
            #expect(store.waveform(for: "a") == nil)
            store.store(levels(1), for: "a")
            store.store(levels(2, count: 100), for: "b")
            #expect(store.waveform(for: "a") == levels(1))
            #expect(store.waveform(for: "b") == levels(2, count: 100))
            #expect(store.waveform(for: "c") == nil)
            #expect(WaveformStore(url: url).waveform(for: "a") == levels(1))

            store.store(levels(3), for: "a")
            #expect(store.waveform(for: "a") == levels(3))
        }

        @Test("an empty waveform isn't stored")
        func empty() throws {
            let store = WaveformStore(url: try TempDir().path("w.sqlite"))
            store.store(Waveform(rms: []), for: "a")
            #expect(store.waveform(for: "a") == nil)
        }

        @Test("another format version drops what is there")
        func formatVersion() throws {
            let url = try TempDir().path("w.sqlite")
            let store = WaveformStore(url: url)
            store.store(levels(1), for: "a")

            var handle: OpaquePointer?
            #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
            #expect(sqlite3_exec(handle, "PRAGMA user_version = \(Waveform.formatVersion + 1)", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(handle)

            let reopened = WaveformStore(url: url)
            #expect(reopened.waveform(for: "a") == nil)
            reopened.store(levels(2), for: "b")
            #expect(WaveformStore(url: url).waveform(for: "b") == levels(2))
        }

        @Test("an entry that can't be decoded is ignored")
        func undecodable() throws {
            let url = try TempDir().path("w.sqlite")
            let store = WaveformStore(url: url)
            store.store(levels(1), for: "good")

            var handle: OpaquePointer?
            #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
            #expect(sqlite3_exec(handle, "INSERT INTO waveforms (key, data) VALUES ('bad', x'0102030405060708')", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(handle)

            #expect(store.waveform(for: "bad") == nil)
            #expect(store.waveform(for: "good") == levels(1))
        }

        @Test("a broken database file means no waveforms, not a crash")
        func broken() throws {
            let dir = try TempDir()
            let url = try dir.write("w.sqlite", Data("this is not a database, not even close".utf8) + Data(repeating: 7, count: 4096))
            let store = WaveformStore(url: url)
            #expect(store.waveform(for: "a") == nil)
            store.store(levels(1), for: "a")
            #expect(store.waveform(for: "a") == nil)
        }

        @Test("a store whose directory can't be created finds nothing")
        func unusableLocation() throws {
            let dir = try TempDir()
            let file = try dir.write("file")
            let store = WaveformStore(url: file.appendingPathComponent("sub/w.sqlite"))
            store.store(levels(1), for: "a")
            #expect(store.waveform(for: "a") == nil)
        }
    }

    @MainActor @Suite("Waveform: key")
    struct WaveformKeyTests {
        @Test("the key follows path, size and modification date, and nothing else")
        func changes() throws {
            let dir = try TempDir()
            let file = try dir.write("a.bin", Data(count: 10))
            let key = try #require(WaveformKey.make(url: file))
            #expect(WaveformKey.make(url: file) == key)
            #expect(key.count == 64)

            // Same size, another date
            let before = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            try FileManager.default.setAttributes([.modificationDate: before.addingTimeInterval(60)], ofItemAtPath: file.path)
            let touched = try #require(WaveformKey.make(url: file))
            #expect(touched != key)

            // Another size, the same date
            let modified = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            try Data(count: 11).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            let grown = try #require(WaveformKey.make(url: file))
            #expect(grown != touched)

            // The same content somewhere else
            let copy = try dir.write("b.bin", Data(count: 11))
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: copy.path)
            #expect(WaveformKey.make(url: copy) != grown)
        }

        @Test("a file that can't be examined has no key")
        func missing() throws {
            #expect(WaveformKey.make(url: try TempDir().path("nope.flac")) == nil)
        }
    }
}
