import Foundation
import SQLite3

/// Persistent cache of album art thumbnails: album key (`AlbumKey`) -> encoded image (JPEG/PNG bytes).
///
/// Plain SQLite through the system `libsqlite3` (no dependency, no model file, the same engine Core Data
/// would sit on). One table, one connection, WAL journal. Lives in `AppPaths.cacheDir` and can be deleted at any time.
/// The thumbnail size is stored in `PRAGMA user_version`; if it ever changes the old thumbnails are dropped.
///
/// Failures are logged and swallowed (reads return nil, writes are dropped): a broken cache must never break
/// the app, albums simply fall back to the generated placeholder.
final class CoverStore: @unchecked Sendable {
    static let shared = CoverStore(url: AppPaths.current.coverCacheURL, thumbnailPixels: AppConstants.coverThumbnailPixels)

    private let url: URL
    private let thumbnailPixels: Int
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var opened = false

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, thumbnailPixels: Int) {
        self.url = url
        self.thumbnailPixels = thumbnailPixels
    }

    /// The cached thumbnail of an album, nil if there is none.
    func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = openIfNeeded() else { return nil }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM covers WHERE key = ?1", -1, &statement, nil) == SQLITE_OK else {
            logFailure("select")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bindKey(key, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    /// Adds or replaces the thumbnail of an album.
    func store(_ data: Data, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = openIfNeeded() else { return }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO covers (key, data) VALUES (?1, ?2)", -1, &statement, nil) == SQLITE_OK else {
            logFailure("insert")
            return
        }
        defer { sqlite3_finalize(statement) }
        bindKey(key, to: statement)
        data.withUnsafeBytes { raw in
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
            Log.error("cover cache: can't create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
            return nil
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            Log.error("cover cache: can't open \(url.path): \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")")
            sqlite3_close(handle)
            return nil
        }

        // WAL + NORMAL: a commit doesn't wait for the disk, which matters with thousands of small inserts.
        // The worst case after a crash is losing the last few thumbnails, they are rebuilt on the next import.
        let storedSize = Self.queryInt(handle, "PRAGMA user_version")
        var setup = ["PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL"]
        if storedSize != 0 && storedSize != Int32(thumbnailPixels) { setup.append("DROP TABLE IF EXISTS covers") }
        setup.append("CREATE TABLE IF NOT EXISTS covers (key TEXT PRIMARY KEY, data BLOB NOT NULL)")
        setup.append("PRAGMA user_version = \(thumbnailPixels)")

        for sql in setup where sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            Log.error("cover cache: \(sql): \(String(cString: sqlite3_errmsg(handle)))")
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
        Log.error("cover cache: \(what) failed: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection")")
    }
}
