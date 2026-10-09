// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import SQLite3

/// Where a track's waveform is kept: a hash of the file's path, size and modification date. One `stat`, no content
/// hashing (that would read 170 MB over a network share). A file that is edited or replaced gets a new key; one that
/// was moved is analysed again (under a second for a normal track).
enum WaveformKey {
    /// `nil` if the file can't be examined (gone, share unavailable). Blocking: call it off the main thread.
    static func make(url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let text = "\(url.path)|\(size.int64Value)|\(Int64((modified.timeIntervalSince1970 * 1000).rounded()))"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Persistent store of waveforms: `WaveformKey` -> the whole record of a track (`Waveform.encoded()`, lzfse compressed;
/// ~30 KB, mostly the spectrogram bands, which don't compress much).
///
/// The same kind of thing as `CoverStore`/`LyricsStore` (plain SQLite through the system `libsqlite3`, one table, one
/// connection behind a lock, WAL, in `AppPaths.cacheDir`). `PRAGMA user_version` holds `Waveform.formatVersion`; a
/// different one drops the table. The app never removes anything otherwise (entries of files that are gone or changed
/// stay), the file is safe to delete by hand.
///
/// Failures are logged and swallowed (reads find nothing, writes are dropped): a broken store must never break the
/// app, tracks simply have no waveform then.
final class WaveformStore: @unchecked Sendable {
    static let shared = WaveformStore(url: AppPaths.current.waveformCacheURL)

    private let url: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var opened = false

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) {
        self.url = url
    }

    /// The stored waveform under `key`, nil if there is none.
    func waveform(for key: String) -> Waveform? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = openIfNeeded() else { return nil }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM waveforms WHERE key = ?1", -1, &statement, nil) == SQLITE_OK else {
            logFailure("select")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bindKey(key, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0 else { return nil }
        let compressed = Data(bytes: bytes, count: count)
        guard let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let waveform = Waveform(encoded: data) else {
            Log.error("waveform cache: undecodable entry, ignored")
            return nil
        }
        return waveform
    }

    /// Adds or replaces the waveform under `key`.
    func store(_ waveform: Waveform, for key: String) {
        guard !waveform.isEmpty, let compressed = try? (waveform.encoded() as NSData).compressed(using: .lzfse) as Data else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db = openIfNeeded() else { return }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO waveforms (key, data) VALUES (?1, ?2)", -1, &statement, nil) == SQLITE_OK else {
            logFailure("insert")
            return
        }
        defer { sqlite3_finalize(statement) }
        bindKey(key, to: statement)
        compressed.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(raw.count), Self.transient)
        }
        if sqlite3_step(statement) != SQLITE_DONE { logFailure("insert") }
    }

    // MARK: - Setup

    /// Opens (and if needed creates) the database on first use. Caller holds the lock.
    private func openIfNeeded() -> OpaquePointer? {
        if opened { return db }
        opened = true

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            Log.error("waveform cache: can't create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
            return nil
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            Log.error("waveform cache: can't open \(url.path): \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")")
            sqlite3_close(handle)
            return nil
        }

        let version = Waveform.formatVersion
        let storedVersion = Self.queryInt(handle, "PRAGMA user_version")
        var setup = ["PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL"]
        if storedVersion != 0 && storedVersion != Int32(version) { setup.append("DROP TABLE IF EXISTS waveforms") }
        setup.append("CREATE TABLE IF NOT EXISTS waveforms (key TEXT PRIMARY KEY, data BLOB NOT NULL)")
        setup.append("PRAGMA user_version = \(version)")

        for sql in setup where sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            Log.error("waveform cache: \(sql): \(String(cString: sqlite3_errmsg(handle)))")
            sqlite3_close(handle)
            return nil
        }
        db = handle
        return handle
    }

    private static func queryInt(_ db: OpaquePointer?, _ sql: String) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    /// Explicit byte length: never rely on NUL termination for keys.
    private func bindKey(_ key: String, to statement: OpaquePointer?) {
        let bytes = key.utf8CString                                             // includes the trailing NUL
        bytes.withUnsafeBufferPointer {
            _ = sqlite3_bind_text(statement, 1, $0.baseAddress, Int32($0.count - 1), Self.transient)
        }
    }

    private func logFailure(_ what: String) {
        Log.error("waveform cache: \(what) failed: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection")")
    }
}
