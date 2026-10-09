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
            let waveform = Waveform(levels: [0, 255])
            #expect(waveform.columns(4) == [0, 0, 1, 1])
            #expect(waveform.columns(2) == [0, 1])
        }

        @Test("one column is the RMS of everything: levels are averaged as power")
        func oneColumn() {
            #expect(Waveform(levels: [255, 255, 255]).columns(1) == [1])
            // half the power = -3 dB = 57/60
            let half = Waveform(levels: [0, 255]).columns(1)[0]
            #expect(abs(half - 57.0 / 60.0) < 0.001)
            #expect(Waveform(levels: [0, 0, 0]).columns(1) == [0])
        }

        @Test("group sizes that don't divide the bucket count lose nothing and repeat nothing")
        func uneven() {
            let waveform = Waveform(levels: [UInt8](repeating: 200, count: Waveform.bucketCount))
            for count in [1, 7, 100, 333, 1000, 2047, 2048, 5000] {
                let columns = waveform.columns(count)
                #expect(columns.count == count)
                #expect(columns.allSatisfy { abs($0 - 200.0 / 255.0) < 0.001 }, "count \(count)")
            }
            // Every bucket belongs to a column: a single loud one shows up whatever the grouping.
            var levels = [UInt8](repeating: 0, count: Waveform.bucketCount)
            levels[1500] = 255
            for count in [10, 100, 333, 1000] {
                #expect(Waveform(levels: levels).columns(count).filter { $0 > 0 }.count == 1, "count \(count)")
            }
        }

        @Test("nothing to reduce, nothing to draw")
        func empty() {
            #expect(Waveform(levels: []).columns(10).isEmpty)
            #expect(Waveform(levels: [1, 2]).columns(0).isEmpty)
            #expect(Waveform(levels: [1, 2]).columns(-3).isEmpty)
        }

        @Test("bars: the loudest column is full height, the others are their relative amplitude to the exponent, quieter than the range is 0")
        func bars() {
            // 255 = 0 dB, 170 = -20 dB, 85 = -40 dB, 0 = silence
            let waveform = Waveform(levels: [255, 170, 85, 0])
            let linear = waveform.bars(4, rangeDB: 30)
            #expect(linear[0] == 1)
            #expect(abs(linear[1] - 0.1) < 0.005)   // -20 dB = amplitude 0.1
            #expect(linear[2] == 0)                  // beyond the range
            #expect(linear[3] == 0)
            // A smaller exponent lifts the quiet parts: 0.1^0.5
            let lifted = waveform.bars(4, rangeDB: 30, exponent: 0.5)
            #expect(abs(lifted[1] - 0.316) < 0.005)
            // Relative to the loudest, not to full scale.
            let quiet = Waveform(levels: [170, 85]).bars(2, rangeDB: 40)
            #expect(quiet[0] == 1)
            #expect(abs(quiet[1] - 0.1) < 0.005)
        }

        @Test("bars: a passage 12 dB quieter is clearly shorter, not nearly as tall as the loud one")
        func barsContrast() {
            // 255 = 0 dB, 204 = -12 dB
            let bars = Waveform(levels: [255, 204]).bars(2, rangeDB: 48, exponent: 0.6)
            #expect(bars[0] == 1)
            #expect(bars[1] < 0.5)
            #expect(bars[1] > 0.35)
        }

        @Test("a silent track has bars of height 0")
        func silentBars() {
            #expect(Waveform(levels: [0, 0, 0, 0]).bars(3, rangeDB: 40) == [0, 0, 0])
        }
    }

    // MARK: - Store

    @MainActor @Suite("Waveform: store")
    struct WaveformStoreTests {
        private func levels(_ seed: Int, count: Int = Waveform.bucketCount) -> Waveform {
            Waveform(levels: (0..<count).map { UInt8(($0 * 7 + seed) % 256) })
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
            store.store(Waveform(levels: []), for: "a")
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
