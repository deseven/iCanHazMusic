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

    /// How many logs of earlier runs are kept next to the current one: `app.log.1` (the previous run) and up.
    static let keptOldLogs = 4

    /// Starts duplicating the log into `url`, which is created empty; the logs of earlier runs are shifted to `url.1`,
    /// `url.2`, ... (`keptOldLogs` of them, the oldest is dropped). Meant to be called once at launch; tests don't call
    /// it, so they never write into a real working directory.
    static func startFileLogging(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateLogs(at: url)
        guard fm.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            print("[\(AppConstants.appShortName)] ERROR: can't open log file \(url.path)")
            return
        }
        file = handle
    }

    /// `url` becomes `url.1`, `url.1` becomes `url.2` and so on; `url.{keep}` is removed. Missing ones are skipped.
    static func rotateLogs(at url: URL, keep: Int = keptOldLogs) {
        let fm = FileManager.default
        func old(_ n: Int) -> URL { url.appendingPathExtension(String(n)) }
        guard keep > 0 else {
            try? fm.removeItem(at: url)
            return
        }
        try? fm.removeItem(at: old(keep))
        for n in stride(from: keep - 1, through: 1, by: -1) {
            try? fm.moveItem(at: old(n), to: old(n + 1))
        }
        try? fm.moveItem(at: url, to: old(1))
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
