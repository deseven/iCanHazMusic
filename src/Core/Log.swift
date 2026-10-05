// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Simple logger for debug output: every line goes to stdout and, once `startFileLogging(at:)` was called, to a log
/// file. Lines look like `[2026-10-05 14:03:09] [iCHM] message` (local time; the `[iCHM]` prefix makes the app easy
/// to identify).
enum Log {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var file: FileHandle?
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Starts duplicating the log into `url`, which is created empty (an earlier log is overwritten). Meant to be
    /// called once at launch; tests don't call it, so they never write into a real working directory.
    static func startFileLogging(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            print("[\(AppConstants.appShortName)] ERROR: can't open log file \(url.path)")
            return
        }
        file = handle
    }

    static func info(_ message: String) {
        write("[\(AppConstants.appShortName)] \(message)")
    }

    static func error(_ message: String) {
        write("[\(AppConstants.appShortName)] ERROR: \(message)")
    }

    private static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
        if let data = (line + "\n").data(using: .utf8) {
            try? file?.write(contentsOf: data)
        }
    }
}
