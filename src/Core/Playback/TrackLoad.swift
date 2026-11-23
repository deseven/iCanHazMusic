// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What the current track is waiting for before its audio comes out: a song being downloaded, a file being opened or
/// read (a drive that spins up, a network share that is slow). Shown in place of the play symbol of its row.
enum TrackLoad: Equatable, Sendable {
    /// Waiting, and there is nothing to tell how long it takes: a file that is being opened, a download whose size the
    /// server hasn't said yet (or that is done and has yet to be opened).
    case indeterminate
    /// A download is under way: how much of the file is there, 0...1.
    case progress(Double)
}
