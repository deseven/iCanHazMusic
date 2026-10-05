// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation

/// Quality of the sample rate conversion `TrackDecoder` does for files whose rate differs from the output's
/// (`playback.resample_quality` in the config). The raw value is what the config file holds.
enum ResampleQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case max

    static let `default`: ResampleQuality = .high

    var id: String { rawValue }

    var avQuality: AVAudioQuality {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .max: .max
        }
    }
}
