// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

/// A file that doesn't answer, like one on a network share that went away: a named pipe, whose opening for reading
/// blocks until somebody opens it for writing. `release()` (also on deinit) lets whoever is stuck opening it go; they
/// then find an empty file.
final class HungFile {
    let url: URL

    init(in dir: TempDir, name: String = "hung.flac") throws {
        url = dir.path(name)
        guard mkfifo(url.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Opens and closes the writing end for as long as somebody waits to read (the reader may open the file more
    /// than once), so that no thread stays blocked on it.
    func release() {
        for _ in 0..<50 {
            let fd = open(url.path, O_WRONLY | O_NONBLOCK)
            guard fd >= 0 else { return }   // ENXIO: nobody is waiting to read
            close(fd)
            usleep(10_000)
        }
    }

    deinit { release() }
}
