// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What the engine plays as one track: a whole audio file, or a part of one (a track of a CUE sheet). Positions and
/// lengths the engine reports are relative to the start of the part.
struct PlaybackSource: Equatable, Hashable, Sendable {
    let url: URL
    /// Seconds into the file where the track starts.
    let start: TimeInterval
    /// Seconds into the file where it ends; `nil` = at the end of the file.
    let end: TimeInterval?

    init(url: URL, start: TimeInterval = 0, end: TimeInterval? = nil) {
        self.url = url
        self.start = max(0, start)
        self.end = end
    }

    var isWholeFile: Bool { start <= 0 && end == nil }

    /// The length of the track in a file that is `fileDuration` seconds long (the end is cut at the end of the file).
    func length(inFileOf fileDuration: TimeInterval) -> TimeInterval {
        max(0, min(end ?? fileDuration, fileDuration) - start)
    }
}
