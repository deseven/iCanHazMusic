// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Accelerate
import Foundation

/// The constants of the spectral measurement behind `Waveform.bands` (changing any of them means a new
/// `Waveform.formatVersion`).
enum SpectralLayout {
    /// Window of one FFT frame (a power of two) and its log2.
    static let fftSize = 4096
    static let fftLog2 = 12
    /// Distance between frames: about two per bucket, within these.
    static let minHop: Int64 = 256
    static let maxHop: Int64 = 2048
    /// The `Waveform.bandCount` bands are log spaced between these (Hz). Bands above 95% of the Nyquist frequency of a
    /// file are empty (0), so a band means the same frequencies whatever the sample rate.
    static let lowestHz = 40.0
    static let highestHz = 16_000.0
    /// Pitch classes, summed over this range (Hz).
    static let chromaCount = 12
    static let chromaLowHz = 220.0
    static let chromaHighHz = 4200.0
}

/// One FFT frame -> power per band and strength per pitch class. Not thread safe (scratch memory): one per worker.
final class SpectralProcessor {
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: SpectralLayout.fftSize)
    /// Turns the (twice too large) power of Accelerate's real FFT into mean square of the signal.
    private let powerScale: Float
    private var binLow: [Int] = []
    private var binHigh: [Int] = []
    private var chromaBins: [Int] = []
    private var chromaClasses: [Int] = []

    private let windowed = UnsafeMutablePointer<Float>.allocate(capacity: SpectralLayout.fftSize)
    private let real = UnsafeMutablePointer<Float>.allocate(capacity: SpectralLayout.fftSize / 2)
    private let imaginary = UnsafeMutablePointer<Float>.allocate(capacity: SpectralLayout.fftSize / 2)
    private let power = UnsafeMutablePointer<Float>.allocate(capacity: SpectralLayout.fftSize / 2)
    private let magnitude = UnsafeMutablePointer<Float>.allocate(capacity: SpectralLayout.fftSize / 2)

    /// Mean square of the signal in each band of the last frame (the bands add up to the mean square of the frame, DC
    /// and what is outside the bands left out).
    private(set) var bandPower = [Float](repeating: 0, count: Waveform.bandCount)
    /// Strength of each pitch class (C = 0) in the last frame.
    private(set) var chroma = [Float](repeating: 0, count: SpectralLayout.chromaCount)

    init(sampleRate: Double) {
        let size = SpectralLayout.fftSize
        setup = vDSP_create_fftsetup(vDSP_Length(SpectralLayout.fftLog2), FFTRadix(kFFTRadix2))!
        for i in 0..<size { window[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(size))) }
        // Parseval: one-sided sum of |X|^2 = N * sum(w^2) * meanSquare / 2, and Accelerate's output is 2X.
        let energy = window.reduce(0) { $0 + $1 * $1 }
        powerScale = 1 / (2 * Float(size) * energy)

        let binWidth = sampleRate / Double(size)
        let limit = sampleRate / 2 * 0.95
        let half = size / 2
        let ratio = pow(SpectralLayout.highestHz / SpectralLayout.lowestHz, 1 / Double(Waveform.bandCount))
        var previous = 1
        for band in 0..<Waveform.bandCount {
            let from = SpectralLayout.lowestHz * pow(ratio, Double(band))
            let to = SpectralLayout.lowestHz * pow(ratio, Double(band + 1))
            let low = max(previous, Int((from / binWidth).rounded(.down)))
            guard from < limit, low < half else {
                binLow.append(0)
                binHigh.append(0)
                continue
            }
            let high = min(half, max(low + 1, Int((min(to, limit) / binWidth).rounded(.up))))
            binLow.append(low)
            binHigh.append(high)
            previous = high
        }

        let chromaLow = Int((SpectralLayout.chromaLowHz / binWidth).rounded(.up))
        let chromaHigh = min(half - 1, Int((SpectralLayout.chromaHighHz / binWidth).rounded(.down)))
        if chromaLow <= chromaHigh {
            for bin in chromaLow...chromaHigh {
                let midi = 69 + 12 * log2(Double(bin) * binWidth / 440)
                chromaBins.append(bin)
                chromaClasses.append(((Int(midi.rounded()) % 12) + 12) % 12)
            }
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        windowed.deallocate()
        real.deallocate()
        imaginary.deallocate()
        power.deallocate()
        magnitude.deallocate()
    }

    /// Measures the `SpectralLayout.fftSize` samples at `samples`.
    func process(_ samples: UnsafePointer<Float>) {
        let size = SpectralLayout.fftSize
        let half = vDSP_Length(size / 2)
        window.withUnsafeBufferPointer { vDSP_vmul(samples, 1, $0.baseAddress!, 1, windowed, 1, vDSP_Length(size)) }
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ctoz($0, 2, &split, 1, half) }
        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(SpectralLayout.fftLog2), FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, power, 1, half)
        // Bin 0 holds DC and (packed in the imaginary part) Nyquist: neither is a band.
        power[0] = 0
        var scale = powerScale
        vDSP_vsmul(power, 1, &scale, power, 1, half)

        for band in 0..<Waveform.bandCount {
            let count = binHigh[band] - binLow[band]
            var sum: Float = 0
            if count > 0 { vDSP_sve(power + binLow[band], 1, &sum, vDSP_Length(count)) }
            bandPower[band] = sum
        }

        var count = Int32(size / 2)
        vvsqrtf(magnitude, power, &count)
        for k in 0..<SpectralLayout.chromaCount { chroma[k] = 0 }
        for i in 0..<chromaBins.count { chroma[chromaClasses[i]] += magnitude[chromaBins[i]] }
    }
}
