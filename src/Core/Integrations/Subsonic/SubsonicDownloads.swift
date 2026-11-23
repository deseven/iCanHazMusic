// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// Where to get a song from: the address of the connection that is to be used now.
struct SubsonicDownloadTarget: Sendable {
    let url: URL
    let route: SubsonicRoute
}

/// What `SubsonicDownloads` asks of the connections (`SubsonicService` answers; tests do it with a stand-in).
protocol SubsonicDownloadProvider: Sendable {
    /// The URL to download `songID` of `connection` from, at an address that is not in `avoiding` (the ones that just
    /// failed); nil if there is none left. Throws if the connection can't be used at all (removed, switched off).
    func downloadTarget(connection: UUID, songID: String, avoiding: Set<SubsonicRoute>) async throws -> SubsonicDownloadTarget?

    /// What came of a download from `route`: nil for a success. The connection takes note (its status, which address to use).
    func downloadDidFinish(connection: UUID, route: SubsonicRoute, error: SubsonicError?) async

    /// What the connection is called, for the log.
    func displayName(of connection: UUID) async -> String
}

/// The files of the songs that play (or are about to), kept in `directory` (`.cache/subsonic`), in the `downloads`
/// directory of each connection (`{connection id}/downloads`; its `playlists` directory is not this class's).
///
/// - `acquire` starts the download of a song if it isn't under way (or done) and returns a `SourceLease`; every
///   holder of a lease for the same song shares the one file. The decoder of the track holds one while it exists, the
///   engine one for the track that comes next (earlier than the decoder is made), the waveform one while it measures.
/// - What happens to a file when the last lease is let go of depends on the cache size of its connection
///   (`SubsonicCacheSize`, handed over by `setCachePolicies`; a connection that isn't known has none):
///   - none: the download is cancelled and the file deleted at once, and everything of the connection is deleted at
///     launch and quit;
///   - a size: the file stays, with its modification time set to the last use (an `acquire` of it, and the end of its
///     last lease), and a file that comes by a new download is followed by trimming the connection's directory to the
///     size, the least recently used files first (never one that is leased: a size can be exceeded for a while). The
///     same is done at launch;
///   - unlimited: the file stays, nothing is ever trimmed.
///   A connection that was removed has its directory deleted (and its downloads cancelled).
/// - **Pinned** files (`setPinnedSongs`: the songs of the playlists that are downloaded automatically,
///   `SubsonicAutoDownloads`) are outside of all that: they stay whatever the cache size is (none included, also at
///   launch and quit), and don't count towards it. The list is kept in `{connection id}/pinned.json`, so it holds from
///   the start of the next run (and for a connection that is switched off). A file that is no longer pinned is a cached
///   file like any other from then on: the cache size applies to it at once (`reconcile`).
/// - A song is downloaded whole, with `download` (the original file, nothing transcoded), to `{connection id}/downloads/{hash
///   of the song id}.{suffix}`, from a `.part` file next to it that is renamed when it is complete: nothing opens half a
///   file, and a file that is there is complete. The partial files of a crash are deleted when this is made.
/// - Downloads go to the address the connection is using; one that fails because the address can't be reached is
///   tried on the other one, if there is one, and the connection learns of both.
/// - A download that failed is forgotten at once (the leases that wait for it get the error), so the next `acquire`
///   tries again.
final class SubsonicDownloads: SourceFetching, @unchecked Sendable {
    /// Gets `from` into the file `to`, telling `progress` how far it is (see `SubsonicTransfer`).
    typealias Transfer = @Sendable (_ from: URL, _ to: URL, _ progress: @escaping SubsonicTransfer.Progress) async throws -> Void

    @MainActor static let shared: SubsonicDownloads = {
        let service = SubsonicService.shared
        let downloads = SubsonicDownloads(directory: AppPaths.current.subsonicCacheDir, provider: service)
        service.onCachePoliciesChanged = { [weak downloads] policies in downloads?.cachePoliciesChanged(policies) }
        downloads.setCachePolicies(service.cachePolicies)
        // What an earlier run left: trimmed to the sizes, and what no longer has a cache deleted.
        Task.detached(priority: .utility) { [downloads] in await downloads.reconcile() }
        return downloads
    }()

    private enum State {
        case running
        case done(URL)
        case failed(String)
        case cancelled
    }

    /// Everything but the constants is guarded by the lock of the `SubsonicDownloads` that owns it.
    private final class Entry: @unchecked Sendable {
        let key: String
        let ref: SubsonicRef
        let file: URL
        /// Where this download writes to: its own file, so that one that was abandoned and is still winding down can't
        /// get in the way of the next one for the same song.
        let part: URL
        var leases = 0
        var state = State.running
        var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]
        var task: Task<Void, Never>?
        /// How much of the file the running transfer has written, and how big it will be (nil: not known).
        var received: Int64 = 0
        var expected: Int64?

        init(key: String, ref: SubsonicRef, file: URL) {
            self.key = key
            self.ref = ref
            self.file = file
            part = URL(fileURLWithPath: file.path + ".\(UUID().uuidString.prefix(6)).part")
        }

        /// The names of the files of this entry as `connection id/name`.
        var names: [String] {
            let prefix = ref.connection.uuidString + "/"
            return [prefix + file.lastPathComponent, prefix + part.lastPathComponent]
        }
    }

    private struct CachedFile {
        let url: URL
        let size: Int64
        let date: Date
    }

    private let directory: URL
    private let provider: any SubsonicDownloadProvider
    private let transfer: Transfer
    /// How many bytes a GB of a cache size is (a parameter for the tests).
    private let gigabyte: Int64
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var policies: [UUID: SubsonicCacheSize] = [:]
    /// The names of the pinned files of each connection (in its `downloads` directory).
    private var pinned: [UUID: Set<String>] = [:]

    /// The list of the pinned files of a connection, in its directory (next to `downloads`).
    static let pinnedFileName = "pinned.json"

    /// Deletes the partial files that are left in `directory`.
    init(directory: URL, provider: any SubsonicDownloadProvider, gigabyte: Int64 = 1_000_000_000,
         transfer: @escaping Transfer = { try await SubsonicTransfer.download(from: $0, to: $1, progress: $2) }) {
        self.directory = directory
        self.provider = provider
        self.transfer = transfer
        self.gigabyte = gigabyte
        for connection in Self.children(of: directory) {
            Self.removePartialFiles(in: connection.appendingPathComponent(AppPaths.subsonicDownloadsDirName, isDirectory: true))
            if let id = UUID(uuidString: connection.lastPathComponent),
               let names = Self.loadPinned(from: connection.appendingPathComponent(Self.pinnedFileName)), !names.isEmpty {
                pinned[id] = names
            }
        }
    }

    /// How many songs are downloaded or being downloaded (and held by a lease).
    var count: Int { lock.withLock { entries.count } }

    // MARK: - Cache policy

    /// Takes over the cache size of every connection (all of the known ones, disabled included). Returns whether anything
    /// differs from before, in which case `reconcile()` has something to do.
    @discardableResult
    func setCachePolicies(_ new: [UUID: SubsonicCacheSize]) -> Bool {
        lock.withLock {
            guard policies != new else { return false }
            policies = new
            return true
        }
    }

    private func cachePoliciesChanged(_ new: [UUID: SubsonicCacheSize]) {
        guard setCachePolicies(new) else { return }
        Task.detached(priority: .utility) { [self] in await reconcile() }
    }

    private func policy(of connection: UUID) -> SubsonicCacheSize {
        lock.withLock { policies[connection] ?? .off }
    }

    /// Makes the files on disk match the cache sizes: the directories of connections that are gone are deleted, so are the
    /// files of a connection without a cache that nothing holds, and a connection with a size is trimmed to it. Run at
    /// launch and whenever the cache sizes change.
    func reconcile() async {
        for child in Self.children(of: directory) {
            guard let id = UUID(uuidString: child.lastPathComponent) else {
                try? FileManager.default.removeItem(at: child)
                continue
            }
            await reconcile(id)
        }
    }

    /// The same for one connection.
    func reconcile(_ id: UUID) async {
        switch lock.withLock({ policies[id] }) {
        case nil:
            removeCache(of: id)
        case .off?:
            removeFiles(of: id)
        case .unlimited?:
            break
        case .limited?:
            await trim(id)
        }
    }

    /// Deletes the downloads of the connections that have no cache (but the pinned ones), and the partial files of the
    /// others; the app is quitting, nothing plays any more. What isn't a connection's or is one that was removed goes
    /// entirely; the cached playlists of a connection stay (they aren't downloads).
    func cleanUpAtQuit() {
        let (policies, pinned) = lock.withLock { (self.policies, self.pinned) }
        for child in Self.children(of: directory) {
            guard let id = UUID(uuidString: child.lastPathComponent), let policy = policies[id] else {
                try? FileManager.default.removeItem(at: child)
                continue
            }
            let downloads = child.appendingPathComponent(AppPaths.subsonicDownloadsDirName, isDirectory: true)
            if policy.keepsFiles {
                Self.removePartialFiles(in: downloads)
            } else if let kept = pinned[id], !kept.isEmpty {
                for file in Self.children(of: downloads) where !kept.contains(file.lastPathComponent) {
                    try? FileManager.default.removeItem(at: file)
                }
            } else {
                try? FileManager.default.removeItem(at: downloads)
            }
        }
    }

    /// The connection was removed: its downloads are cancelled and everything it has in the cache is deleted.
    func removeCache(of connection: UUID) {
        let running: [Task<Void, Never>] = lock.withLock {
            let tasks = entries.values.filter { $0.ref.connection == connection }.compactMap { entry -> Task<Void, Never>? in
                if case .running = entry.state { return entry.task }
                return nil
            }
            pinned[connection] = nil
            try? FileManager.default.removeItem(at: connectionDirectory(connection))
            return tasks
        }
        for task in running { task.cancel() }
        Log.info("subsonic: the cache of a removed connection is deleted")
    }

    /// Deletes every file of a connection without a cache that nothing holds and isn't pinned.
    private func removeFiles(of connection: UUID) {
        let directory = downloadsDirectory(connection)
        lock.withLock {
            let held = heldNames()
            for file in Self.children(of: directory) where !held.contains(connection.uuidString + "/" + file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        Self.removeIfEmpty(directory)
    }

    /// Deletes the files of a connection that were used least recently until what is left fits its cache size. Files that
    /// are held are never deleted (the size can be exceeded while they are); pinned files are neither deleted nor counted.
    private func trim(_ connection: UUID) async {
        guard case .limited(let gigabytes) = policy(of: connection) else { return }
        let limit = Int64(gigabytes) * gigabyte
        let pins = lock.withLock { pinned[connection] ?? [] }
        var files = Self.completeFiles(in: downloadsDirectory(connection)).filter { !pins.contains($0.url.lastPathComponent) }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        files.sort { $0.date < $1.date }
        let name = await provider.displayName(of: connection)

        var removed = 0
        var freed: Int64 = 0
        lock.withLock {
            let held = heldNames()
            for file in files where total > limit {
                guard !held.contains(connection.uuidString + "/" + file.url.lastPathComponent) else { continue }
                guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
                total -= file.size
                freed += file.size
                removed += 1
            }
        }
        if removed > 0 {
            Log.info("subsonic: \(removed) least recently used file(s) of \"\(name)\" deleted from the cache (\(Self.size(freed)) freed)")
        }
    }

    /// The files that must not be deleted (as `connection id/name`): those of the songs that are leased, and the pinned
    /// ones. Called with the lock held.
    private func heldNames() -> Set<String> {
        var names = Set(entries.values.flatMap(\.names))
        for (connection, files) in pinned {
            let prefix = connection.uuidString + "/"
            names.formUnion(files.map { prefix + $0 })
        }
        return names
    }

    /// Whether a file of the connection's `downloads` directory is pinned. Called with the lock held.
    private func isPinned(_ file: URL, of connection: UUID) -> Bool {
        pinned[connection]?.contains(file.lastPathComponent) == true
    }

    /// Whether a file outlives its last lease: the connection has a cache, or it is pinned. Called with the lock held.
    private func keeps(_ file: URL, of connection: UUID) -> Bool {
        (policies[connection] ?? .off).keepsFiles || isPinned(file, of: connection)
    }

    /// Everything of a connection in the cache (its downloads and its cached playlists).
    private func connectionDirectory(_ connection: UUID) -> URL {
        AppPaths.subsonicDir(of: connection, in: directory)
    }

    private func downloadsDirectory(_ connection: UUID) -> URL {
        connectionDirectory(connection).appendingPathComponent(AppPaths.subsonicDownloadsDirName, isDirectory: true)
    }

    /// Deletes the downloaded files of these songs (of one connection) that nothing holds: the playlist they were in is
    /// gone and no other playlist of the connection has them. Songs that are being played or downloaded are left alone
    /// (a file that is held is the business of its last lease), so are pinned ones. Returns how many files were deleted.
    @discardableResult
    func removeFiles(ofSongs refs: [SubsonicRef]) -> Int {
        lock.withLock {
            let held = heldNames()
            var removed = 0
            var directories = Set<URL>()
            for ref in refs {
                let directory = downloadsDirectory(ref.connection)
                directories.insert(directory)
                let name = Self.fileName(of: ref)
                let file = directory.appendingPathComponent(name, isDirectory: false)
                guard !held.contains(ref.connection.uuidString + "/" + name), Self.isFile(file) else { continue }
                if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
            }
            for directory in directories { Self.removeIfEmpty(directory) }
            return removed
        }
    }

    // MARK: - Pinned files

    /// Makes the files of exactly these songs the pinned ones of `connection` (whether they are downloaded yet or not)
    /// and saves the list. Files that are no longer pinned get the connection's cache size applied right away (in the
    /// background). Returns whether anything changed.
    @discardableResult
    func setPinnedSongs(_ refs: [SubsonicRef], of connection: UUID) -> Bool {
        let names = Set(refs.filter { $0.connection == connection }.map(Self.fileName(of:)))
        let file = connectionDirectory(connection).appendingPathComponent(Self.pinnedFileName, isDirectory: false)
        let released: Bool? = lock.withLock {
            let old = pinned[connection] ?? []
            guard old != names else { return nil }
            pinned[connection] = names.isEmpty ? nil : names
            // Saved under the lock: two changes in a row must reach the disk in their order.
            Self.savePinned(names, to: file)
            return !old.subtracting(names).isEmpty
        }
        guard let released else { return false }
        if released { Task.detached(priority: .utility) { [self] in await reconcile(connection) } }
        return true
    }

    /// The pinned files of a connection, by name.
    func pinnedFiles(of connection: UUID) -> Set<String> {
        lock.withLock { pinned[connection] ?? [] }
    }

    /// Which of these songs have their file downloaded (song IDs). Looks at the disk: not for the main thread.
    func downloadedSongs(_ refs: [SubsonicRef]) -> Set<String> {
        Set(refs.filter { ref in
            Self.isFile(downloadsDirectory(ref.connection).appendingPathComponent(Self.fileName(of: ref), isDirectory: false))
        }.map(\.songID))
    }

    private struct PinnedList: Codable {
        var version = 1
        var files: [String]
    }

    private static func loadPinned(from file: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode(PinnedList.self, from: data),
              list.version <= 1 else { return nil }
        return Set(list.files)
    }

    /// Writes the list, or deletes it when there is nothing pinned (and the connection's directory with it, if that is
    /// all it had).
    private static func savePinned(_ names: Set<String>, to file: URL) {
        guard !names.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            _ = rmdir(file.deletingLastPathComponent().path)
            return
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(PinnedList(files: names.sorted())).write(to: file, options: .atomic)
        } catch {
            Log.error("subsonic: can't save the list of the files that are kept (\(file.path)): \(error.localizedDescription)")
        }
    }

    // MARK: - SourceFetching

    func handles(_ url: URL) -> Bool {
        url.subsonicRef != nil
    }

    func acquire(_ url: URL) -> SourceLease {
        guard let ref = url.subsonicRef else {
            return SourceLease(wait: { throw SourceFetchError("not a Subsonic song") }, release: {})
        }
        let key = "\(ref.connection.uuidString):\(ref.songID)"
        lock.lock()
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            let file = downloadsDirectory(ref.connection).appendingPathComponent(Self.fileName(of: ref), isDirectory: false)
            entry = Entry(key: key, ref: ref, file: file)
            entries[key] = entry
            if keeps(file, of: ref.connection), Self.isFile(file) {
                entry.state = .done(file)
                Self.touch(file)
            } else {
                entry.task = Task { [self] in await run(entry) }
            }
        }
        entry.leases += 1
        lock.unlock()
        return SourceLease(wait: { [self] in try await wait(for: entry) }, release: { [self] in release(entry) },
                           progress: { [self] in progress(of: entry) })
    }

    /// How much of the song's file is there while it is downloaded; nil when that isn't known (yet) or it is there.
    private func progress(of entry: Entry) -> Double? {
        lock.withLock {
            guard case .running = entry.state, let expected = entry.expected, expected > 0 else { return nil }
            return min(max(Double(entry.received) / Double(expected), 0), 1)
        }
    }

    /// The name of the file of a song: the same one every time, whatever the song's ID has in it.
    static func fileName(of ref: SubsonicRef) -> String {
        let hash = SHA256.hash(data: Data(ref.songID.utf8)).prefix(16).hexString
        return "\(hash).\(safeSuffix(ref.suffix))"
    }

    /// The suffix as a file extension: letters and digits only (it comes from a server).
    static func safeSuffix(_ suffix: String) -> String {
        let clean = String(suffix.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        return clean.isEmpty ? "audio" : clean
    }

    // MARK: - Leases

    private func release(_ entry: Entry) {
        lock.lock()
        entry.leases -= 1
        guard entry.leases == 0 else {
            lock.unlock()
            return
        }
        if entries[entry.key] === entry { entries[entry.key] = nil }
        var abandoned: [CheckedContinuation<URL, Error>] = []
        if case .running = entry.state {
            entry.state = .cancelled
            abandoned = Array(entry.waiters.values)
            entry.waiters.removeAll()
        }
        let task = entry.task
        // Only a file that was made for this entry is its to delete (a failed or abandoned one made none; the file of
        // that name may be a newer entry's). Deleted under the lock: an `acquire` of the same song right after must
        // find the file gone, not have it taken away from under it.
        if case .done(let file) = entry.state {
            if keeps(file, of: entry.ref.connection) {
                Self.touch(file)
            } else {
                Self.delete(file)
            }
        }
        lock.unlock()

        task?.cancel()
        for waiter in abandoned { waiter.resume(throwing: CancellationError()) }
    }

    private func wait(for entry: Entry) async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let settled: Result<URL, Error>? = lock.withLock {
                    switch entry.state {
                    case .done(let file):
                        return .success(file)
                    case .failed(let message):
                        return .failure(SourceFetchError(message))
                    case .cancelled:
                        return .failure(CancellationError())
                    case .running:
                        entry.waiters[id] = continuation
                        return nil
                    }
                }
                if let settled {
                    continuation.resume(with: settled)
                } else if Task.isCancelled {
                    // Cancelled before the handler below could find the waiter.
                    cancelWaiter(id, of: entry)
                }
            }
        } onCancel: {
            cancelWaiter(id, of: entry)
        }
    }

    private func cancelWaiter(_ id: UUID, of entry: Entry) {
        lock.lock()
        let waiter = entry.waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
    }

    // MARK: - Downloading

    private func run(_ entry: Entry) async {
        let result: Result<Void, Error>
        do {
            try await download(entry)
            try Task.checkCancellation()   // a transfer that finished just as it was called off
            result = .success(())
        } catch {
            result = .failure(error)
        }

        // The file gets its name here, under the lock, and only if somebody still wants it.
        let settled: (waiters: [CheckedContinuation<URL, Error>], state: State)? = lock.withLock {
            guard case .running = entry.state else { return nil }
            let waiters = Array(entry.waiters.values)
            entry.waiters.removeAll()
            var outcome = result
            if case .success = outcome {
                do {
                    try? FileManager.default.removeItem(at: entry.file)
                    try FileManager.default.moveItem(at: entry.part, to: entry.file)
                } catch {
                    outcome = .failure(SubsonicError(.rejected, "can't save the file: \(error.localizedDescription)"))
                }
            }
            switch outcome {
            case .success:
                entry.state = .done(entry.file)
            case .failure(let error):
                entry.state = error is CancellationError ? .cancelled : .failed(Self.message(of: error))
                if entries[entry.key] === entry { entries[entry.key] = nil }
            }
            return (waiters, entry.state)
        }
        guard let (waiters, state) = settled else {
            // Everybody let go of it meanwhile.
            try? FileManager.default.removeItem(at: entry.part)
            return
        }

        // Before anybody is told: the file is leased by then, so a holder (a bulk download that is done with it and
        // lets go) can't see it trimmed from under it later.
        if case .done = state { await trim(entry.ref.connection) }

        for waiter in waiters {
            switch state {
            case .done(let file): waiter.resume(returning: file)
            case .failed(let message): waiter.resume(throwing: SourceFetchError(message))
            case .cancelled, .running: waiter.resume(throwing: CancellationError())
            }
        }
        if case .done = state { return }
        try? FileManager.default.removeItem(at: entry.part)
    }

    /// Gets the file of `entry` into `entry.part`: from the address the connection uses, and if that can't be reached from
    /// the other.
    private func download(_ entry: Entry) async throws {
        let ref = entry.ref
        let part = entry.part
        var avoiding = Set<SubsonicRoute>()
        var lastConnectionError: SubsonicError?

        while true {
            try Task.checkCancellation()
            let target = try await provider.downloadTarget(connection: ref.connection, songID: ref.songID, avoiding: avoiding)
            guard let target else {
                throw lastConnectionError ?? SubsonicError(.connection, "the server can't be reached")
            }
            avoiding.insert(target.route)

            lock.withLock {
                entry.received = 0
                entry.expected = nil
            }
            let started = ContinuousClock.now
            do {
                try await transfer(target.url, part) { [self] received, expected in
                    lock.withLock {
                        entry.received = received
                        entry.expected = expected
                    }
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: part)
                throw CancellationError()
            } catch let error as SubsonicError {
                try? FileManager.default.removeItem(at: part)
                await provider.downloadDidFinish(connection: ref.connection, route: target.route, error: error)
                guard error.kind == .connection else { throw error }
                lastConnectionError = error
                continue
            } catch {
                try? FileManager.default.removeItem(at: part)
                throw SubsonicError(.rejected, "can't save the file: \(error.localizedDescription)")
            }

            await provider.downloadDidFinish(connection: ref.connection, route: target.route, error: nil)
            let size = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value
            let elapsed = (ContinuousClock.now - started).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let detail = size.map { " (\(Self.size($0)) in \(String(format: "%.1f", seconds)) s)" } ?? ""
            Log.info("subsonic: downloaded song \(ref.songID) of \(await provider.displayName(of: ref.connection))\(detail)")
            return
        }
    }

    // MARK: - Files

    private static func message(of error: Error) -> String {
        if let error = error as? SubsonicError { return error.message }
        return error.localizedDescription
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func removePartialFiles(in directory: URL) {
        for file in children(of: directory) where file.pathExtension == "part" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func isFile(_ file: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// The finished files of a connection's directory (the partial ones are not part of the cache yet) with their sizes
    /// and when they were used last.
    private static func completeFiles(in directory: URL) -> [CachedFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.pathExtension != "part" }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                return CachedFile(url: url, size: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? .distantPast)
            }
    }

    /// Marks the file as used now.
    private static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    private static func delete(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        // The downloads directory goes with its last file.
        removeIfEmpty(file.deletingLastPathComponent())
    }

    /// Deletes a connection's downloads directory if it is empty, and the connection's directory if that is empty then
    /// (`rmdir` leaves one that has something in it, e.g. the cached playlists).
    private static func removeIfEmpty(_ downloads: URL) {
        _ = rmdir(downloads.path)
        _ = rmdir(downloads.deletingLastPathComponent().path)
    }
}
