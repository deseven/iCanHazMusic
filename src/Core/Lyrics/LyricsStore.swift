import Foundation
import SQLite3

/// Persistent store of lyrics: `LyricsKey` -> source, text and (if there is one) the synchronised LRC text.
///
/// The same kind of thing as `CoverStore` (plain SQLite through the system `libsqlite3`, one table, one connection,
/// WAL journal, in `AppPaths.cacheDir`). Embedded lyrics are written when the tags of a file are read, so they can
/// be restored by reading the tags again (Reload Tag(s)); the ones from LRCLIB are fetched again when the track
/// plays, if LRCLIB is on.
///
/// Failures are logged and swallowed (reads find nothing, writes are dropped): a broken store must never break the
/// app, tracks simply have no lyrics then.
final class LyricsStore: @unchecked Sendable {
    static let shared = LyricsStore(url: AppPaths.current.lyricsCacheURL)

    private let url: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var opened = false

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) {
        self.url = url
    }

    /// The lyrics stored under `key`, nil if there are none.
    func lyrics(for key: String) -> Lyrics? {
        lock.lock()
        defer { lock.unlock() }
        guard let statement = prepare("SELECT source, plain, synced FROM lyrics WHERE key = ?1", key: key) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let source = text(statement, 0).flatMap(Lyrics.Source.init(rawValue:)),
              let plain = text(statement, 1) else { return nil }
        return Lyrics(source: source, plain: plain, lrc: text(statement, 2))
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let statement = prepare("SELECT 1 FROM lyrics WHERE key = ?1", key: key) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Stores `lyrics` under `key`. With `replacing: false` what is there already stays (LRCLIB never replaces
    /// the lyrics of the file). Returns whether `lyrics` are stored now.
    @discardableResult
    func store(_ lyrics: Lyrics, for key: String, replacing: Bool = true) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let verb = replacing ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        guard let statement = prepare("\(verb) INTO lyrics (key, source, plain, synced) VALUES (?1, ?2, ?3, ?4)", key: key) else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(lyrics.source.rawValue, at: 2, in: statement)
        bind(lyrics.plain, at: 3, in: statement)
        if let lrc = lyrics.lrc { bind(lrc, at: 4, in: statement) } else { sqlite3_bind_null(statement, 4) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            logFailure("insert")
            return false
        }
        return sqlite3_changes(db) > 0
    }

    // MARK: - Setup

    /// A statement for `sql` with the key bound as parameter 1, nil if the store can't be used. Caller holds the lock.
    private func prepare(_ sql: String, key: String) -> OpaquePointer? {
        guard let db = openIfNeeded() else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logFailure("prepare")
            return nil
        }
        bind(key, at: 1, in: statement)
        return statement
    }

    /// Opens (and if needed creates) the database on first use. Caller holds the lock.
    private func openIfNeeded() -> OpaquePointer? {
        if opened { return db }
        opened = true

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            Log.error("lyrics cache: can't create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
            return nil
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            Log.error("lyrics cache: can't open \(url.path): \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")")
            sqlite3_close(handle)
            return nil
        }

        let setup = [
            "PRAGMA journal_mode = WAL",
            "PRAGMA synchronous = NORMAL",
            "CREATE TABLE IF NOT EXISTS lyrics (key TEXT PRIMARY KEY, source TEXT NOT NULL, plain TEXT NOT NULL, synced TEXT)",
        ]
        for sql in setup where sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            Log.error("lyrics cache: \(sql): \(String(cString: sqlite3_errmsg(handle)))")
            sqlite3_close(handle)
            return nil
        }
        db = handle
        return handle
    }

    // MARK: - Helpers

    /// Explicit byte length: never rely on NUL termination.
    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        let bytes = value.utf8CString                                           // includes the trailing NUL
        bytes.withUnsafeBufferPointer {
            _ = sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), Self.transient)
        }
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    private func logFailure(_ what: String) {
        Log.error("lyrics cache: \(what) failed: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection")")
    }
}
