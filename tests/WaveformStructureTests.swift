// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Waveform: structure")
    struct WaveformStructureTests {
        private let bands = Waveform.bandCount

        /// A track of `sounds.count` equally long parts, each of which is one of two timbres (0: low bands loud and
        /// pitch class C, 1: high bands loud and pitch class F#) at its own loudness.
        private func features(_ sounds: [(timbre: Int, loudness: Float)], buckets: Int)
            -> (rmsDB: [Float], bandDB: [Float], chroma: [Float]) {
            var rms: [Float] = []
            var bandDB: [Float] = []
            var chroma: [Float] = []
            for i in 0..<buckets {
                let part = sounds[min(sounds.count - 1, i * sounds.count / buckets)]
                rms.append(part.loudness)
                for band in 0..<bands {
                    let loud = (part.timbre == 0) == (band < bands / 2)
                    // a little ripple so no dimension is perfectly flat
                    bandDB.append((loud ? -30 : -70) + Float((i * 7 + band * 3) % 5) * 0.1)
                }
                for k in 0..<12 { chroma.append(k == (part.timbre == 0 ? 0 : 6) ? 1 : 0.1) }
            }
            return (rms, bandDB, chroma)
        }

        private func analyse(_ sounds: [(timbre: Int, loudness: Float)], seconds: Double = 120, buckets: Int = 1200) -> WaveformStructure {
            let f = features(sounds, buckets: buckets)
            return WaveformStructureAnalyzer.analyse(rmsDB: f.rmsDB, bandDB: f.bandDB, bands: bands, chroma: f.chroma, seconds: seconds)
        }

        @Test("one change of sound is one boundary, in the right place")
        func oneBoundary() {
            let structure = analyse([(0, -20), (1, -14)])
            #expect(structure.boundaries.count == 1)
            if let boundary = structure.boundaries.first { #expect(abs(boundary - 600) <= 30, "at \(boundary)") }
            #expect(structure.labels == [0, 1])
        }

        @Test("a part that comes back gets the label it had")
        func returns() {
            let structure = analyse([(0, -20), (1, -14), (0, -20)])
            #expect(structure.boundaries.count == 2)
            #expect(structure.labels == [0, 1, 0])
            for (found, expected) in zip(structure.boundaries, [400, 800]) { #expect(abs(found - expected) <= 30, "at \(found)") }
        }

        @Test("a track that sounds the same all the way has one section")
        func uniform() {
            let structure = analyse([(0, -20)])
            #expect(structure == .none)
            #expect(structure.labels == [0])
        }

        @Test("a track that is too short, or has too few buckets, has no sections")
        func tooShort() {
            #expect(analyse([(0, -20), (1, -14)], seconds: 10, buckets: 1200) == .none)
            #expect(analyse([(0, -20), (1, -14)], seconds: 120, buckets: 30) == .none)
            #expect(WaveformStructureAnalyzer.analyse(rmsDB: [], bandDB: [], bands: bands, chroma: [], seconds: 120) == .none)
            // Inputs that don't fit together.
            #expect(WaveformStructureAnalyzer.analyse(rmsDB: [Float](repeating: 0, count: 1200), bandDB: [1], bands: bands,
                                                      chroma: [], seconds: 120) == .none)
        }

        @Test("boundaries ascend, stay inside the track and come with one label per section")
        func wellFormed() {
            let structure = analyse([(0, -20), (1, -14), (0, -20), (1, -10), (0, -25), (1, -14)], seconds: 300, buckets: 2048)
            #expect(structure.labels.count == structure.boundaries.count + 1)
            #expect(structure.boundaries == structure.boundaries.sorted())
            #expect(structure.boundaries.allSatisfy { $0 > 0 && $0 < 2048 })
            #expect(Set(structure.boundaries).count == structure.boundaries.count)
            // labels are numbered in order of first appearance
            var seen = -1
            for label in structure.labels {
                #expect(label <= seen + 1)
                seen = max(seen, label)
            }
        }
    }
}
