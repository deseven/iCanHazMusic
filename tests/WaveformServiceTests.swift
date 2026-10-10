// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

/// An analyser that answers from a table, can be held back per file, and counts its calls.
private final class AnalyserStub: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [URL: WaveformAnalysis] = [:]
    private var held: Set<URL> = []
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var log: [URL] = []

    var calls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func answer(_ url: URL, with analysis: WaveformAnalysis?) {
        lock.lock()
        results[url] = analysis
        lock.unlock()
    }

    func hold(_ url: URL) {
        lock.lock()
        held.insert(url)
        lock.unlock()
    }

    func release(_ url: URL) {
        lock.lock()
        held.remove(url)
        let continuations = waiters.removeValue(forKey: url) ?? []
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func analyse(_ url: URL) async -> WaveformAnalysis? {
        record(url)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !wait(for: url, continuation) { continuation.resume() }
        }
        return result(for: url)
    }

    private func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        log.append(url)
    }

    /// Parks the continuation if `url` is held; false if it isn't.
    private func wait(for url: URL, _ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard held.contains(url) else { return false }
        waiters[url, default: []].append(continuation)
        return true
    }

    private func result(for url: URL) -> WaveformAnalysis? {
        lock.lock()
        defer { lock.unlock() }
        return results[url]
    }
}

extension AllTests {
    @MainActor @Suite("Waveform: service")
    struct WaveformServiceTests {
        private struct Rig {
            let dir: TempDir
            let store: WaveformStore
            let settings: NowPlayingSettings
            let analyser: AnalyserStub
            let service: WaveformService
        }

        private func rig(style: SeekbarStyle = .waveformRMS) throws -> Rig {
            let dir = try TempDir()
            let store = WaveformStore(url: dir.path(".cache/waveforms.sqlite"))
            let settings = NowPlayingSettings()
            settings.style = style
            let analyser = AnalyserStub()
            let service = WaveformService(settings: settings, store: store) { await analyser.analyse($0) }
            return Rig(dir: dir, store: store, settings: settings, analyser: analyser, service: service)
        }

        private func levels(_ seed: Int) -> Waveform {
            Waveform(rms: (0..<64).map { UInt8(($0 + seed) % 256) })
        }

        private func track(_ url: URL?, _ n: Int = 1) -> PlayedTrack {
            PlayedTrack(artist: "A", title: "T\(n)", album: "B", duration: 100,
                        startedAt: Date(timeIntervalSince1970: Double(n)), url: url)
        }

        @Test("with the default style nothing is looked up or made")
        func defaultStyle() async throws {
            let rig = try rig(style: .standard)
            let file = try rig.dir.write("a.flac", Data(count: 10))
            rig.analyser.answer(file, with: WaveformAnalysis(waveform: levels(1), isComplete: true))
            rig.service.trackDidStart(track(file))
            try await Task.sleep(for: .milliseconds(100))
            #expect(rig.analyser.calls.isEmpty)
            #expect(rig.service.current == nil)
            #expect(rig.service.state == .idle)
            #expect(rig.store.waveform(for: try #require(WaveformKey.make(url: file))) == nil)
        }

        @Test("a stored waveform is used without analysing")
        func cacheHit() async throws {
            let rig = try rig()
            let file = try rig.dir.write("a.flac", Data(count: 10))
            rig.store.store(levels(5), for: try #require(WaveformKey.make(url: file)))
            rig.service.trackDidStart(track(file))
            #expect(rig.service.state == .analysing)
            #expect(await waitUntil { rig.service.current == levels(5) })
            #expect(rig.service.state == .idle)
            #expect(rig.analyser.calls.isEmpty)
        }

        @Test("a miss analyses, stores and publishes")
        func miss() async throws {
            let rig = try rig()
            let file = try rig.dir.write("a.flac", Data(count: 10))
            rig.analyser.answer(file, with: WaveformAnalysis(waveform: levels(7), isComplete: true))
            rig.service.trackDidStart(track(file))
            #expect(await waitUntil { rig.service.current == levels(7) })
            #expect(rig.service.state == .idle)
            #expect(rig.analyser.calls == [file])
            #expect(rig.store.waveform(for: try #require(WaveformKey.make(url: file))) == levels(7))

            // The next time it comes from the store.
            rig.service.trackDidEnd(track(file), playedSeconds: 1)
            #expect(rig.service.current == nil)
            rig.service.trackDidStart(track(file, 2))
            #expect(await waitUntil { rig.service.current == levels(7) })
            #expect(rig.analyser.calls.count == 1)
        }

        @Test("an incomplete result is shown but not stored")
        func incomplete() async throws {
            let rig = try rig()
            let file = try rig.dir.write("a.flac", Data(count: 10))
            rig.analyser.answer(file, with: WaveformAnalysis(waveform: levels(3), isComplete: false))
            rig.service.trackDidStart(track(file))
            #expect(await waitUntil { rig.service.current == levels(3) })
            #expect(rig.store.waveform(for: try #require(WaveformKey.make(url: file))) == nil)
        }

        @Test("a failure is remembered: the same file isn't analysed again")
        func failure() async throws {
            let rig = try rig()
            let file = try rig.dir.write("a.flac", Data(count: 10))
            rig.analyser.answer(file, with: nil)
            rig.service.trackDidStart(track(file))
            #expect(await waitUntil { rig.service.state == .unavailable })
            #expect(rig.service.current == nil)

            rig.service.trackDidEnd(track(file), playedSeconds: 1)
            #expect(rig.service.state == .idle)
            rig.service.trackDidStart(track(file, 2))
            #expect(await waitUntil { rig.service.state == .unavailable })
            #expect(rig.analyser.calls.count == 1)
        }

        @Test("a file that can't be examined or a track without a file has none")
        func noFile() async throws {
            let rig = try rig()
            rig.service.trackDidStart(track(nil))
            #expect(rig.service.state == .idle)
            rig.service.trackDidStart(track(rig.dir.path("gone.flac"), 2))
            #expect(await waitUntil { rig.service.state == .unavailable })
            #expect(rig.analyser.calls.isEmpty)
        }

        @Test("the pass of a track that was left is cancelled in effect: its late result is not shown, but kept")
        func lateResult() async throws {
            let rig = try rig()
            let first = try rig.dir.write("a.flac", Data(count: 10))
            let second = try rig.dir.write("b.flac", Data(count: 20))
            rig.analyser.hold(first)
            rig.analyser.answer(first, with: WaveformAnalysis(waveform: levels(1), isComplete: true))
            rig.analyser.answer(second, with: WaveformAnalysis(waveform: levels(2), isComplete: true))

            rig.service.trackDidStart(track(first, 1))
            #expect(await waitUntil { rig.analyser.calls == [first] })
            rig.service.trackDidEnd(track(first, 1), playedSeconds: 1)
            rig.service.trackDidStart(track(second, 2))
            #expect(await waitUntil { rig.service.current == levels(2) })

            rig.analyser.release(first)
            let firstKey = try #require(WaveformKey.make(url: first))
            #expect(await waitUntil { rig.store.waveform(for: firstKey) == levels(1) })
            #expect(rig.service.current == levels(2))
            #expect(rig.service.state == .idle)
        }

        @Test("the end of the track drops the waveform; the end of another track doesn't")
        func trackEnd() async throws {
            let rig = try rig()
            let file = try rig.dir.write("a.flac", Data(count: 10))
            rig.analyser.answer(file, with: WaveformAnalysis(waveform: levels(1), isComplete: true))
            rig.service.trackDidStart(track(file, 1))
            #expect(await waitUntil { rig.service.current != nil })
            rig.service.trackDidEnd(track(file, 9), playedSeconds: 1)
            #expect(rig.service.current != nil)
            rig.service.trackDidEnd(track(file, 1), playedSeconds: 1)
            #expect(rig.service.current == nil)
        }

        @Test("switching the style mid-track starts the work, switching back lets go of it but keeps the store")
        func switchingStyle() async throws {
            let rig = try rig(style: .standard)
            let file = try rig.dir.write("a.flac", Data(count: 10))
            rig.analyser.answer(file, with: WaveformAnalysis(waveform: levels(4), isComplete: true))
            rig.service.trackDidStart(track(file))
            #expect(rig.service.state == .idle)

            rig.settings.style = .waveformRMS
            #expect(rig.service.state == .analysing)
            #expect(await waitUntil { rig.service.current == levels(4) })

            rig.settings.style = .standard
            #expect(rig.service.current == nil)
            #expect(rig.service.state == .idle)
            #expect(rig.store.waveform(for: try #require(WaveformKey.make(url: file))) == levels(4))

            // Picked again: from the store.
            rig.settings.style = .waveformRMS
            #expect(await waitUntil { rig.service.current == levels(4) })
            #expect(rig.analyser.calls.count == 1)
        }

        @Test("switching between visual styles keeps the waveform: nothing is looked up or analysed again")
        func switchingBetweenVisualStyles() async throws {
            let rig = try rig(style: .waveformRMS)
            let file = try rig.dir.write("a.flac", Data(count: 10))
            rig.analyser.answer(file, with: WaveformAnalysis(waveform: levels(6), isComplete: true))
            rig.service.trackDidStart(track(file))
            #expect(await waitUntil { rig.service.current == levels(6) })

            for style in [SeekbarStyle.waveformPeakRMS, .waveformTriBand, .waveformStructure, .spectrogram] {
                rig.settings.style = style
                #expect(rig.service.current == levels(6), "\(style)")
                #expect(rig.service.state == .idle, "\(style)")
            }
            #expect(rig.analyser.calls.count == 1)

            // Mid-pass: the pass goes on.
            let other = try rig.dir.write("b.flac", Data(count: 20))
            rig.analyser.hold(other)
            rig.analyser.answer(other, with: WaveformAnalysis(waveform: levels(9), isComplete: true))
            rig.service.trackDidEnd(track(file), playedSeconds: 1)
            rig.service.trackDidStart(track(other, 2))
            #expect(await waitUntil { rig.analyser.calls.count == 2 })
            rig.settings.style = .waveformRMS
            #expect(rig.service.state == .analysing)
            rig.analyser.release(other)
            #expect(await waitUntil { rig.service.current == levels(9) })
            #expect(rig.analyser.calls.count == 2)
        }

        @Test("switching the style while nothing plays does nothing")
        func switchingWhileStopped() throws {
            let rig = try rig(style: .standard)
            rig.settings.style = .waveformRMS
            #expect(rig.service.state == .idle)
            #expect(rig.service.current == nil)
        }

        @Test("a pass that is running when the style goes back to default stores nothing half done")
        func switchingDuringPass() async throws {
            let rig = try rig()
            let file = try rig.dir.write("a.flac", Data(count: 10))
            rig.analyser.hold(file)
            rig.analyser.answer(file, with: nil)
            rig.service.trackDidStart(track(file))
            #expect(await waitUntil { rig.analyser.calls.count == 1 })
            rig.settings.style = .standard
            rig.analyser.release(file)
            try await Task.sleep(for: .milliseconds(100))
            #expect(rig.service.current == nil)
            #expect(rig.service.state == .idle)
            // The failure of a cancelled pass isn't remembered.
            rig.settings.style = .waveformRMS
            rig.analyser.answer(file, with: WaveformAnalysis(waveform: levels(8), isComplete: true))
            #expect(await waitUntil { rig.service.current == levels(8) })
        }
    }
}
