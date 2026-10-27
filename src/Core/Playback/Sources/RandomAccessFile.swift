// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

/// A file opened for reading at any position with `pread`, which is how the decoders of the extra formats get at their
/// data (they are written for files of their own, and are handed this instead, see `vendor/README.md`).
///
/// - Nothing is read ahead or cached: whatever the decoder asks for is asked of the file system, so a file that stops
///   answering (a network share that went away) blocks the caller and nobody else. An error ends a read like the end of
///   the file does, it is never retried.
/// - There is no position: every read says where it starts, so the object can be shared by whoever needs one.
final class RandomAccessFile {
    /// The length in bytes; -1 for what isn't a regular file (a pipe), whose length nobody knows.
    let size: Int64
    private let descriptor: Int32

    /// Blocks while the file does (opening a named pipe, or a file on a stalled share).
    init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw PCMSourceError("can't open the file: \(String(cString: strerror(errno)))") }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw PCMSourceError("can't open the file: \(reason)")
        }
        self.descriptor = descriptor
        size = info.st_mode & S_IFMT == S_IFREG ? Int64(info.st_size) : -1
    }

    deinit { close(descriptor) }

    /// Reads up to `count` bytes at `offset` into `buffer`, as many as there are: fewer only at the end of the file or
    /// at an error. Returns how many; -1 if the very first read failed.
    func read(at offset: Int64, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        var total = 0
        while total < count {
            let got = pread(descriptor, buffer + total, count - total, off_t(offset) + off_t(total))
            if got > 0 {
                total += got
            } else if got == 0 {
                break
            } else if errno != EINTR {
                return total > 0 ? total : -1
            }
        }
        return total
    }
}
