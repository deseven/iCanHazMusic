// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation
import Testing
@testable import iCanHazMusic

/// Songs that are files of the fixtures: `provide` says which one (waiting as long as it likes, or failing).
final class FakeFetcher: SourceFetching, @unchecked Sendable {
    typealias Provide = @Sendable (SubsonicRef) async throws -> URL

    static let connection = UUID()

    static func song(_ id: String) -> URL {
        SubsonicRef(connection: connection, songID: id, suffix: "flac").url
    }

    private let lock = NSLock()
    private var acquiredURLs: [URL] = []
    private var liveCount = 0
    private var peakCount = 0
    private let provide: Provide
    private let progress: @Sendable (SubsonicRef) -> Double?

    /// `progress`: how far the (pretend) download of a song is.
    init(_ provide: @escaping Provide, progress: @escaping @Sendable (SubsonicRef) -> Double? = { _ in nil }) {
        self.provide = provide
        self.progress = progress
    }

    var acquired: [URL] { lock.withLock { acquiredURLs } }
    var live: Int { lock.withLock { liveCount } }
    /// The most leases that were held at once.
    var peak: Int { lock.withLock { peakCount } }

    func handles(_ url: URL) -> Bool { url.subsonicRef != nil }

    func acquire(_ url: URL) -> SourceLease {
        lock.withLock {
            acquiredURLs.append(url)
            liveCount += 1
            peakCount = max(peakCount, liveCount)
        }
        let ref = url.subsonicRef!
        return SourceLease(wait: { [provide] in try await provide(ref) },
                           release: { [self] in lock.withLock { liveCount -= 1 } },
                           progress: { [progress] in progress(ref) })
    }
}

/// The connections as `SubsonicDownloads` asks them.
final class FakeDownloadProvider: SubsonicDownloadProvider, @unchecked Sendable {
    typealias Target = @Sendable (_ connection: UUID, _ songID: String, _ avoiding: Set<SubsonicRoute>) throws -> SubsonicDownloadTarget?

    private let lock = NSLock()
    private var finishedCalls: [(SubsonicRoute, String?)] = []
    private let target: Target

    init(_ target: @escaping Target = { _, songID, avoiding in
        avoiding.isEmpty ? SubsonicDownloadTarget(url: URL(string: "https://x.org/\(songID)")!, route: .public) : nil
    }) {
        self.target = target
    }

    /// What the downloads reported: the address and the error (nil: it went through).
    var finished: [(route: SubsonicRoute, error: String?)] { lock.withLock { finishedCalls.map { ($0.0, $0.1) } } }

    func downloadTarget(connection: UUID, songID: String, avoiding: Set<SubsonicRoute>) async throws -> SubsonicDownloadTarget? {
        try target(connection, songID, avoiding)
    }

    func downloadDidFinish(connection: UUID, route: SubsonicRoute, error: SubsonicError?) async {
        lock.withLock { finishedCalls.append((route, error?.message)) }
    }

    func displayName(of connection: UUID) async -> String { "Test" }
}

extension AllTests {
    // MARK: - Downloads

    @MainActor @Suite("Subsonic downloads")
    struct SubsonicDownloadsTests {
        private static let connection = UUID()

        private func url(_ song: String, suffix: String = "flac") -> URL {
            SubsonicRef(connection: Self.connection, songID: song, suffix: suffix).url
        }

        /// A `transfer` that writes `data(url)` to the file and counts its calls.
        private final class Transfers: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [URL] = []
            let data: @Sendable (URL) async throws -> Data

            init(_ data: @escaping @Sendable (URL) async throws -> Data = { Data($0.absoluteString.utf8) }) {
                self.data = data
            }

            var calls: [URL] { lock.withLock { urls } }

            var transfer: SubsonicDownloads.Transfer {
                { [self] from, to, _ in
                    lock.withLock { urls.append(from) }
                    let bytes = try await data(from)
                    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: to)
                }
            }
        }

        /// `cache`: the cache size of the connection (none by default); a GB is 10 bytes here, so a few bytes of
        /// "audio" are a cache that is full.
        private func make(_ transfers: Transfers = Transfers(), provider: FakeDownloadProvider = FakeDownloadProvider(),
                          directory: URL? = nil, cache: SubsonicCacheSize? = nil) throws -> (SubsonicDownloads, URL) {
            let directory = try directory ?? TempDir().path("subsonic")
            let downloads = SubsonicDownloads(directory: directory, provider: provider, gigabyte: 10, transfer: transfers.transfer)
            if let cache { downloads.setCachePolicies([Self.connection: cache]) }
            return (downloads, directory)
        }

        /// The names of the files that are in the directory of the connection.
        private func files(_ directory: URL, of connection: UUID? = nil) -> [String] {
            let connection = connection ?? Self.connection
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(connection.uuidString).appendingPathComponent("downloads").path)) ?? []
            return names.sorted()
        }

        /// The file of a song in the cache, whether it is there or not.
        private func cachedFile(_ directory: URL, _ song: String) -> URL {
            directory.appendingPathComponent(Self.connection.uuidString).appendingPathComponent("downloads")
                .appendingPathComponent(SubsonicDownloads.fileName(of: SubsonicRef(connection: Self.connection, songID: song, suffix: "flac")))
        }

        private func setAge(_ file: URL, seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: file.path)
        }

        private func modified(_ file: URL) throws -> Date {
            try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        }



        @Test("a song is downloaded to a file with its suffix, and the file is gone when the lease is")
        func lifecycle() async throws {
            let transfers = Transfers()
            let (downloads, directory) = try make(transfers)
            var lease: SourceLease? = downloads.acquire(url("s1", suffix: "FLAC"))
            let file = try await #require(lease).file()
            #expect(file.pathExtension == "flac")
            #expect(file.path.hasPrefix(directory.path + "/" + Self.connection.uuidString + "/downloads/"))
            #expect(try Data(contentsOf: file) == Data("https://x.org/s1".utf8))
            #expect(files(directory).filter { $0.hasSuffix(".part") }.isEmpty)
            #expect(downloads.count == 1)

            lease = nil
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(downloads.count == 0)
        }

        @Test("everybody who needs a song shares one download and one file, which stays until the last lets go")
        func sharing() async throws {
            let transfers = Transfers()
            let (downloads, _) = try make(transfers)
            var first: SourceLease? = downloads.acquire(url("s1"))
            var second: SourceLease? = downloads.acquire(url("s1"))
            let other = downloads.acquire(url("s2"))
            let file = try await #require(first).file()
            #expect(try await #require(second).file() == file)
            _ = try await other.file()
            #expect(transfers.calls.count == 2)

            first = nil
            #expect(FileManager.default.fileExists(atPath: file.path))
            second = nil
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }

        @Test("a song that was downloaded earlier is not downloaded again while somebody holds it")
        func lateJoiner() async throws {
            let transfers = Transfers()
            let (downloads, _) = try make(transfers)
            let first = downloads.acquire(url("s1"))
            let file = try await first.file()
            let late = downloads.acquire(url("s1"))
            #expect(try await late.file() == file)
            #expect(transfers.calls.count == 1)
        }

        @Test("a failed download tells its waiters, is forgotten, and the next lease tries again")
        func failure() async throws {
            let attempts = AttemptCounter()
            let transfers = Transfers { _ in
                if attempts.next() == 1 { throw SubsonicError(.rejected, "no such song") }
                return Data("ok".utf8)
            }
            let (downloads, _) = try make(transfers)

            let failing = downloads.acquire(url("s1"))
            await #expect(throws: SourceFetchError("no such song")) { _ = try await failing.file() }
            #expect(downloads.count == 0)

            let retry = downloads.acquire(url("s1"))
            #expect(try await retry.file().lastPathComponent.hasSuffix(".flac"))
            #expect(transfers.calls.count == 2)
        }

        @Test("an address that can't be reached is given up for the other one, and the connection is told of both")
        func fallback() async throws {
            let provider = FakeDownloadProvider { _, songID, avoiding in
                if !avoiding.contains(.local) { return SubsonicDownloadTarget(url: URL(string: "http://192.168.1.2/\(songID)")!, route: .local) }
                if !avoiding.contains(.public) { return SubsonicDownloadTarget(url: URL(string: "https://x.org/\(songID)")!, route: .public) }
                return nil
            }
            let transfers = Transfers { url in
                if url.host == "192.168.1.2" { throw SubsonicError(.connection, "refused") }
                return Data("from the public address".utf8)
            }
            let (downloads, _) = try make(transfers, provider: provider)
            let lease = downloads.acquire(url("s1"))
            let file = try await lease.file()
            #expect(try Data(contentsOf: file) == Data("from the public address".utf8))
            #expect(provider.finished.map(\.route) == [.local, .public])
            #expect(provider.finished.map(\.error) == ["refused", nil])
        }

        @Test("when no address works, the last connection error is the answer")
        func nothingWorks() async throws {
            let transfers = Transfers { _ in throw SubsonicError(.connection, "timed out") }
            let (downloads, _) = try make(transfers)
            await #expect(throws: SourceFetchError("timed out")) { _ = try await downloads.acquire(url("s1")).file() }
        }

        @Test("a server that says no is not tried on the other address")
        func serverRefuses() async throws {
            let provider = FakeDownloadProvider { _, songID, avoiding in
                avoiding.count < 2 ? SubsonicDownloadTarget(url: URL(string: "https://x.org/\(songID)")!, route: avoiding.isEmpty ? .local : .public) : nil
            }
            let transfers = Transfers { _ in throw SubsonicError(.authentication, "Wrong username or password") }
            let (downloads, _) = try make(transfers, provider: provider)
            await #expect(throws: SourceFetchError("Wrong username or password")) { _ = try await downloads.acquire(url("s1")).file() }
            #expect(transfers.calls.count == 1)
            #expect(provider.finished.map(\.error) == ["Wrong username or password"])
        }

        @Test("a connection that is gone or switched off makes the download fail with the reason")
        func unavailable() async throws {
            let provider = FakeDownloadProvider { _, _, _ in throw SubsonicError(.rejected, "its connection was removed") }
            let (downloads, _) = try make(provider: provider)
            await #expect(throws: SourceFetchError("its connection was removed")) { _ = try await downloads.acquire(url("s1")).file() }
        }

        @Test("the lease tells how far the download is once the size is known, and nothing before or after")
        func progress() async throws {
            let gate = Gate()
            let downloads = SubsonicDownloads(directory: try TempDir().path("subsonic"), provider: FakeDownloadProvider(),
                                              gigabyte: 10) { _, to, progress in
                progress(0, 200)   // the answer's headers
                progress(50, 200)
                await gate.wait()
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: 200).write(to: to)
            }
            let lease = downloads.acquire(url("s1"))
            #expect(await waitUntil { lease.progress() == 0.25 })

            gate.open()
            _ = try await lease.file()
            #expect(lease.progress() == nil)
        }

        @Test("the lease has no progress while the size is not known")
        func progressWithoutSize() async throws {
            let gate = Gate()
            let downloads = SubsonicDownloads(directory: try TempDir().path("subsonic"), provider: FakeDownloadProvider(),
                                              gigabyte: 10) { _, to, progress in
                progress(50, nil)
                await gate.wait()
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(count: 50).write(to: to)
            }
            let lease = downloads.acquire(url("s1"))
            try await Task.sleep(for: .milliseconds(50))
            #expect(lease.progress() == nil)
            gate.open()
            _ = try await lease.file()
        }

        @Test("a waiter that is cancelled stops waiting at once, and the download goes on for the others")
        func cancelledWait() async throws {
            let gate = Gate()
            let transfers = Transfers { _ in
                await gate.wait()
                return Data("late".utf8)
            }
            let (downloads, _) = try make(transfers)
            let lease = downloads.acquire(url("s1"))
            let waiting = Task { try await lease.file() }
            try await Task.sleep(for: .milliseconds(50))
            waiting.cancel()
            await #expect(throws: CancellationError.self) { _ = try await waiting.value }

            gate.open()
            #expect(try Data(contentsOf: try await lease.file()) == Data("late".utf8))
        }

        @Test("letting go of a song that is being downloaded cancels it and leaves nothing behind")
        func abandoned() async throws {
            let gate = Gate()
            let started = Gate()
            let transfers = Transfers { _ in
                started.open()
                await gate.wait()
                return Data("never wanted".utf8)
            }
            let (downloads, directory) = try make(transfers)
            var lease: SourceLease? = downloads.acquire(url("s1"))
            await started.wait()
            lease = nil
            #expect(downloads.count == 0)
            gate.open()
            try await Task.sleep(for: .milliseconds(100))
            let left = (FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String]) ?? []
            #expect(left.filter { !$0.hasSuffix(Self.connection.uuidString) && !$0.hasSuffix("downloads") }.isEmpty, "left: \(left)")
            _ = lease
        }

        @Test("the partial files a crash left are deleted when the downloads are made")
        func partialFiles() throws {
            let dir = try TempDir()
            let id = Self.connection.uuidString
            try dir.write("subsonic/\(id)/downloads/old.flac.abc123.part", Data("half".utf8))
            try dir.write("subsonic/\(id)/downloads/old.flac", Data("whole".utf8))
            let (_, directory) = try make(directory: dir.path("subsonic"))
            #expect(files(directory) == ["old.flac"])
        }

        // MARK: Cache

        @Test("with a cache, the file stays when the lease goes and is used again without a download")
        func cacheKeeps() async throws {
            let transfers = Transfers()
            let (downloads, directory) = try make(transfers, cache: .limited(gigabytes: 5))
            var lease: SourceLease? = downloads.acquire(url("s1"))
            let file = try await #require(lease).file()
            lease = nil
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(downloads.count == 0)

            let again = downloads.acquire(url("s1"))
            #expect(try await again.file() == file)
            #expect(transfers.calls.count == 1)
            #expect(files(directory).count == 1)
        }

        @Test("a song that was cached by an earlier run is played from the cache")
        func cacheFromEarlierRun() async throws {
            let transfers = Transfers()
            let dir = try TempDir()
            let directory = dir.path("subsonic")
            try dir.write("subsonic/\(Self.connection.uuidString)/downloads/\(SubsonicDownloads.fileName(of: SubsonicRef(connection: Self.connection, songID: "s1", suffix: "flac")))", Data("earlier".utf8))
            let (downloads, _) = try make(transfers, directory: directory, cache: .unlimited)
            let file = try await downloads.acquire(url("s1")).file()
            #expect(try Data(contentsOf: file) == Data("earlier".utf8))
            #expect(transfers.calls.isEmpty)
        }

        @Test("every use of a cached file marks it as used now")
        func touching() async throws {
            let (downloads, directory) = try make(cache: .limited(gigabytes: 5))
            var lease: SourceLease? = downloads.acquire(url("s1"))
            let file = try await #require(lease).file()
            lease = nil

            try setAge(file, seconds: 3600)
            lease = downloads.acquire(url("s1"))
            #expect(try modified(file).timeIntervalSinceNow > -60)

            lease = nil
            try setAge(file, seconds: 3600)
            lease = downloads.acquire(url("s1"))
            _ = try await #require(lease).file()
            lease = nil
            #expect(try modified(cachedFile(directory, "s1")).timeIntervalSinceNow > -60)
        }

        @Test("after a download the cache is trimmed to its size, the files used longest ago first")
        func trimming() async throws {
            let transfers = Transfers { _ in Data("1234".utf8) }   // 4 bytes of a 10 byte cache
            let (downloads, directory) = try make(transfers, cache: .limited(gigabytes: 1))
            for (song, age) in [("s1", 1000.0), ("s2", 500.0)] {
                do {
                    let lease = downloads.acquire(url(song))
                    _ = try await lease.file()
                }
                try setAge(cachedFile(directory, song), seconds: age)   // after the lease: letting go of it marks it used
            }
            #expect(files(directory).count == 2)

            let third = downloads.acquire(url("s3"))
            _ = try await third.file()
            #expect(!FileManager.default.fileExists(atPath: cachedFile(directory, "s1").path))
            #expect(FileManager.default.fileExists(atPath: cachedFile(directory, "s2").path))
            #expect(FileManager.default.fileExists(atPath: cachedFile(directory, "s3").path))
            _ = third
        }

        @Test("a file that is held is never trimmed, the size is only enforced once it is let go of")
        func trimmingSkipsHeld() async throws {
            let transfers = Transfers { _ in Data("1234".utf8) }
            let (downloads, directory) = try make(transfers, cache: .limited(gigabytes: 1))
            var leases: [SourceLease] = []
            for song in ["s1", "s2", "s3"] {
                let lease = downloads.acquire(url(song))
                _ = try await lease.file()
                leases.append(lease)
            }
            #expect(files(directory).count == 3)   // 12 of 10 bytes, all in use

            leases.removeAll()
            for (song, age) in [("s1", 1000.0), ("s2", 900.0), ("s3", 800.0)] {
                try setAge(cachedFile(directory, song), seconds: age)
            }
            await downloads.reconcile()
            #expect(files(directory).count == 2)
            #expect(!FileManager.default.fileExists(atPath: cachedFile(directory, "s1").path))
        }

        @Test("an unlimited cache is never trimmed")
        func unlimited() async throws {
            let transfers = Transfers { _ in Data("1234567890".utf8) }
            let (downloads, directory) = try make(transfers, cache: .unlimited)
            for song in ["s1", "s2", "s3"] { _ = try await downloads.acquire(url(song)).file() }
            try await Task.sleep(for: .milliseconds(100))
            await downloads.reconcile()
            #expect(files(directory).count == 3)
        }

        @Test("at launch (reconcile) a cache is trimmed, one without a size is emptied, one of a connection that is gone is deleted")
        func reconciling() async throws {
            let dir = try TempDir()
            let other = UUID()
            let gone = UUID()
            func write(_ connection: UUID, _ name: String, age: TimeInterval) throws {
                try dir.write("subsonic/\(connection.uuidString)/downloads/\(name)", Data("1234".utf8))
                try setAge(dir.path("subsonic/\(connection.uuidString)/downloads/\(name)"), seconds: age)
            }
            for (name, age) in [("a.flac", 300.0), ("b.flac", 200.0), ("c.flac", 100.0)] {
                try write(Self.connection, name, age: age)
                try write(other, name, age: age)
            }
            try write(gone, "a.flac", age: 1)
            let (downloads, directory) = try make(directory: dir.path("subsonic"))
            downloads.setCachePolicies([Self.connection: .limited(gigabytes: 1), other: .off])
            await downloads.reconcile()

            #expect(files(directory) == ["b.flac", "c.flac"])
            #expect(files(directory, of: other).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(other.uuidString).path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(gone.uuidString).path))
        }

        @Test("changing a cache to none deletes what nothing holds")
        func switchedOff() async throws {
            let (downloads, directory) = try make(cache: .unlimited)
            let held = downloads.acquire(url("s1"))
            _ = try await held.file()
            _ = try await downloads.acquire(url("s2")).file()
            #expect(files(directory).count == 2)

            downloads.setCachePolicies([Self.connection: .off])
            await downloads.reconcile()
            #expect(files(directory) == [cachedFile(directory, "s1").lastPathComponent])
            _ = held
        }

        @Test("the cache of a connection that was removed is deleted, and its downloads are cancelled")
        func removedConnection() async throws {
            let gate = Gate()
            let started = Gate()
            let transfers = Transfers { url in
                if url.lastPathComponent == "slow" {
                    started.open()
                    await gate.wait()
                }
                return Data("1234".utf8)
            }
            let (downloads, directory) = try make(transfers, cache: .unlimited)
            _ = try await downloads.acquire(url("s1")).file()
            #expect(files(directory).count == 1)

            let slow = downloads.acquire(url("slow"))
            await started.wait()
            downloads.removeCache(of: Self.connection)
            gate.open()
            await #expect(throws: CancellationError.self) { _ = try await slow.file() }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.connection.uuidString).path)
                    || files(directory).isEmpty)
        }

        private func ref(_ song: String) -> SubsonicRef {
            SubsonicRef(connection: Self.connection, songID: song, suffix: "flac")
        }

        @Test("a pinned file stays when its lease goes, without a cache too, and is used again without a download")
        func pinnedWithoutCache() async throws {
            let transfers = Transfers()
            let (downloads, directory) = try make(transfers, cache: .off)
            #expect(downloads.setPinnedSongs([ref("s1")], of: Self.connection))
            #expect(!downloads.setPinnedSongs([ref("s1")], of: Self.connection))   // nothing changed
            _ = try await downloads.acquire(url("s1")).file()
            _ = try await downloads.acquire(url("s2")).file()
            #expect(files(directory) == [cachedFile(directory, "s1").lastPathComponent])

            _ = try await downloads.acquire(url("s1")).file()
            #expect(transfers.calls.count == 2)
            #expect(downloads.downloadedSongs([ref("s1"), ref("s2")]) == ["s1"])
        }

        @Test("pinned files are never trimmed and don't count towards the cache size")
        func pinnedNotTrimmed() async throws {
            let transfers = Transfers { _ in Data("1234".utf8) }   // 4 bytes of a 10 byte cache
            let (downloads, directory) = try make(transfers, cache: .limited(gigabytes: 1))
            downloads.setPinnedSongs([ref("p1"), ref("p2"), ref("p3")], of: Self.connection)
            for song in ["p1", "p2", "p3"] {
                _ = try await downloads.acquire(url(song)).file()
                try setAge(cachedFile(directory, song), seconds: 5000)   // the oldest of all
            }
            for song in ["s1", "s2"] {
                _ = try await downloads.acquire(url(song)).file()
            }
            await downloads.reconcile()
            #expect(files(directory).count == 5)   // 8 bytes that count, of 10
        }

        @Test("pinned files stay at launch and quit with no cache, and the list holds for the next run")
        func pinnedKeptAcrossRuns() async throws {
            let (first, directory) = try make(cache: .off)
            first.setPinnedSongs([ref("s1")], of: Self.connection)
            _ = try await first.acquire(url("s1")).file()
            _ = try await first.acquire(url("s2")).file()
            let held = first.acquire(url("s3"))
            _ = try await held.file()
            first.cleanUpAtQuit()
            #expect(files(directory) == [cachedFile(directory, "s1").lastPathComponent])
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(Self.connection.uuidString)/\(SubsonicDownloads.pinnedFileName)").path))

            let (second, _) = try make(directory: directory, cache: .off)
            #expect(second.pinnedFiles(of: Self.connection) == [cachedFile(directory, "s1").lastPathComponent])
            await second.reconcile()
            #expect(files(directory) == [cachedFile(directory, "s1").lastPathComponent])
            #expect(second.removeFiles(ofSongs: [ref("s1")]) == 0)
            _ = held
        }

        @Test("a file that is no longer pinned gets the cache size at once")
        func unpinned() async throws {
            let (downloads, directory) = try make(cache: .off)
            downloads.setPinnedSongs([ref("s1"), ref("s2")], of: Self.connection)
            _ = try await downloads.acquire(url("s1")).file()
            _ = try await downloads.acquire(url("s2")).file()
            #expect(files(directory).count == 2)

            downloads.setPinnedSongs([ref("s2")], of: Self.connection)
            #expect(await waitUntil { files(directory) == [cachedFile(directory, "s2").lastPathComponent] })
            downloads.setPinnedSongs([], of: Self.connection)
            #expect(await waitUntil { files(directory).isEmpty })
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(Self.connection.uuidString)/\(SubsonicDownloads.pinnedFileName)").path))
        }

        @Test("quitting deletes what connections without a cache have, and the partial files of the others")
        func quitting() throws {
            let dir = try TempDir()
            let other = UUID()
            try dir.write("subsonic/\(Self.connection.uuidString)/downloads/a.flac", Data("kept".utf8))
            try dir.write("subsonic/\(Self.connection.uuidString)/downloads/b.flac.abc123.part", Data("half".utf8))
            try dir.write("subsonic/\(other.uuidString)/downloads/a.flac", Data("gone".utf8))
            let (downloads, directory) = try make(directory: dir.path("subsonic"))
            downloads.setCachePolicies([Self.connection: .unlimited, other: .off])
            // The partial file was there at launch already, so the init deleted it; this one is made since.
            try dir.write("subsonic/\(Self.connection.uuidString)/downloads/c.flac.abc123.part", Data("half".utf8))
            downloads.cleanUpAtQuit()
            #expect(files(directory) == ["a.flac"])
            #expect(files(directory, of: other).isEmpty)
        }

        @Test("the suffix of the file is letters and digits only, whatever the server says")
        func suffix() {
            #expect(SubsonicDownloads.safeSuffix("FLAC") == "flac")
            #expect(SubsonicDownloads.safeSuffix("../../etc/x") == "etcx")
            #expect(SubsonicDownloads.safeSuffix("") == "audio")
            #expect(SubsonicDownloads.safeSuffix("waytoolongasuffix").count == 8)
        }
    }

    // MARK: - Decoder and engine

    @MainActor @Suite("Subsonic playback")
    struct SubsonicPlaybackTests {
        private nonisolated static let files: [String: RampFile] = ["a": .a, "b": .b, "tiny": .tiny]

        private func fetcher(delay: Duration? = nil) -> FakeFetcher {
            FakeFetcher { ref in
                if let delay { try await Task.sleep(for: delay) }
                guard let file = Self.files[ref.songID] else { throw SourceFetchError("song \(ref.songID) is gone") }
                return try file.url()
            }
        }

        private func outputFormat() -> AVAudioFormat {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        }

        // MARK: Decoder

        @Test("a decoder with a lease waits for the file and then decodes it like a local one")
        func decoder() async throws {
            let fetcher = fetcher(delay: .milliseconds(500))
            let url = FakeFetcher.song("tiny")
            let decoder = TrackDecoder(url: url, startSeconds: 0, outputFormat: outputFormat(), lease: fetcher.acquire(url))
            var frames = 0
            loop: while true {
                switch await decoder.next(timeout: 0.3) {   // the wait for the file (0.5 s) isn't what the timeout is about
                case .chunk(let chunk): frames += Int(chunk.buffer.frameLength)
                case .finished: break loop
                case .failed(let message): Issue.record("failed: \(message)"); break loop
                }
            }
            #expect(frames == RampFile.tiny.frames)
            #expect(fetcher.live == 1)
            decoder.cancel()
            #expect(fetcher.live == 0)   // let go of when the decoder is, not when it is freed
        }

        @Test("a file that can't be had fails the decoder with the reason")
        func decoderFailure() async {
            let fetcher = fetcher()
            let url = FakeFetcher.song("missing")
            let decoder = TrackDecoder(url: url, startSeconds: 0, outputFormat: outputFormat(), lease: fetcher.acquire(url))
            guard case .failed(let message) = await decoder.next() else { Issue.record("should fail"); return }
            #expect(message == "song missing is gone")
        }

        @Test("cancelling a decoder that waits for the file ends the wait at once")
        func decoderCancel() async throws {
            let fetcher = fetcher(delay: .seconds(30))
            let url = FakeFetcher.song("a")
            let decoder = TrackDecoder(url: url, startSeconds: 0, outputFormat: outputFormat(), lease: fetcher.acquire(url))
            let result = Task { await decoder.next() }
            try await Task.sleep(for: .milliseconds(50))
            decoder.cancel()
            guard case .finished(let warning) = await result.value else { Issue.record("should be finished"); return }
            #expect(warning == nil)
            #expect(fetcher.live == 0)
        }

        // MARK: Engine

        @Test("the engine plays a song from its downloaded file, sample for sample, and lets go of it at the end")
        func plays() async throws {
            let fetcher = fetcher()
            let rig = EngineRig(fetcher: fetcher)
            rig.engine.start(FakeFetcher.song("a"))
            try await rig.render(RampFile.a.frames + 5000)
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
            #expect(rig.events == ["finished"])
            #expect(rig.started == ["a"])
            #expect(fetcher.live == 0)
        }

        @Test("a download that takes long is waited for, the decoder timeout is not about it")
        func slowDownload() async throws {
            let fetcher = fetcher(delay: .milliseconds(300))
            let rig = EngineRig(fetcher: fetcher)
            rig.engine.decoderTimeout = 0.1
            rig.engine.start(FakeFetcher.song("tiny"))
            try await rig.render(4096)
            #expect(rig.deviation(of: .tiny, from: 0, at: 0, count: RampFile.tiny.frames) == 0)
            #expect(rig.events == ["finished"])
        }

        @Test("a song that can't be fetched fails, and the engine is idle")
        func failing() async throws {
            let fetcher = fetcher()
            let rig = EngineRig(fetcher: fetcher)
            rig.engine.start(FakeFetcher.song("missing"))
            try await rig.render(4096)
            #expect(rig.events == ["failed:missing:current"])
            #expect(!rig.engine.isActive)
            #expect(fetcher.live == 0)
        }

        @Test("the engine tells what the track waits for until its audio is there: the download, or just a wait")
        func load() async throws {
            let gate = Gate()
            let fetcher = FakeFetcher({ ref in
                await gate.wait()
                return try Self.files[ref.songID]!.url()
            }, progress: { _ in 0.4 })
            let rig = EngineRig(fetcher: fetcher)
            #expect(rig.engine.load == nil)

            rig.engine.start(FakeFetcher.song("a"))
            #expect(rig.engine.load == .progress(0.4))

            gate.open()
            try await rig.render(4096)
            #expect(rig.engine.load == nil)

            rig.engine.start(try RampFile.b.url())   // a file of this Mac: nothing to measure
            #expect(rig.engine.load == .indeterminate)
            try await rig.render(4096)
            #expect(rig.engine.load == nil)
        }

        @Test("songs and files of this Mac play one after the other, gaplessly")
        func gapless() async throws {
            let fetcher = fetcher()
            let rig = EngineRig(fetcher: fetcher)
            rig.engine.start(try RampFile.a.url(), next: FakeFetcher.song("b"))
            try await rig.render(RampFile.a.frames + RampFile.b.frames + 3000)
            #expect(rig.deviation(of: .a, from: 0, at: 0, count: RampFile.a.frames) == 0)
            #expect(rig.deviation(of: .b, from: 0, at: RampFile.a.frames, count: RampFile.b.frames) == 0)
            #expect(rig.events == ["advanced", "finished"])
            #expect(fetcher.live == 0)
        }

        @Test("the next song is fetched when the current track is about to end, not at once, and then only once")
        func prefetch() async throws {
            let fetcher = fetcher()
            // A short lookahead: the decoder of the next track is made late, the fetch must be earlier.
            let rig = EngineRig(lookahead: 0.5, fetcher: fetcher)
            rig.engine.prefetchLead = 1
            rig.engine.start(try RampFile.a.url(), next: FakeFetcher.song("b"))   // 3.1 s

            try await rig.render(44100)   // 2.1 s left
            #expect(fetcher.acquired.isEmpty)

            try await rig.render(53_000)  // 0.9 s left, the decoder of a is not through yet
            #expect(fetcher.acquired == [FakeFetcher.song("b")])
            #expect(rig.events.isEmpty)

            try await rig.render(RampFile.a.frames + RampFile.b.frames)
            #expect(rig.deviation(of: .b, from: 0, at: RampFile.a.frames, count: RampFile.b.frames) == 0)
            #expect(rig.events == ["advanced", "finished"])
            #expect(fetcher.live == 0)
            // The decoder of the next track had its own lease, the engine's was the one before it.
            #expect(fetcher.acquired.count == 2)
        }

        @Test("a track that changes while it is waited for loses its fetch")
        func prefetchChanged() async throws {
            let fetcher = fetcher()
            let rig = EngineRig(lookahead: 0.5, fetcher: fetcher)
            rig.engine.prefetchLead = 100   // a track that is shorter than this: fetched at once
            rig.engine.start(try RampFile.a.url(), next: FakeFetcher.song("b"))
            try await rig.render(2048)
            #expect(fetcher.live == 1)

            rig.engine.setNext(FakeFetcher.song("tiny"))
            try await rig.render(2048)
            #expect(fetcher.acquired.map { $0.subsonicRef?.songID } == ["b", "tiny"])
            #expect(fetcher.live == 1)

            rig.engine.setNext(nil as PlaybackSource?)
            try await rig.render(2048)
            #expect(fetcher.live == 0)
        }

        @Test("a seek doesn't lose the file: the new decoder has it before the old one lets go")
        func seek() async throws {
            let fetcher = fetcher()
            let rig = EngineRig(fetcher: fetcher)
            rig.engine.start(FakeFetcher.song("a"))
            try await rig.render(4096)
            #expect(fetcher.live == 1)

            rig.engine.seek(to: 1)
            try await rig.render(4096)
            #expect(fetcher.acquired.count == 2)
            #expect(fetcher.peak == 2)   // never 0 in between
            #expect(fetcher.live == 1)

            rig.engine.stop()
            try await rig.render(4096)
            #expect(fetcher.live == 0)
        }

        @Test("a pause long enough to release the output keeps the file")
        func longPause() async throws {
            let fetcher = fetcher()
            let rig = EngineRig(fetcher: fetcher)
            rig.engine.start(FakeFetcher.song("a"))
            try await rig.render(4096)
            rig.engine.pause()
            try await rig.render(4096)
            rig.engine.releaseIdleOutput()
            #expect(fetcher.live == 1)   // the parked track holds its file

            rig.engine.resume()
            try await rig.render(4096)
            #expect(fetcher.live == 1)   // the new slot took it over
            #expect(fetcher.peak == 2)
            rig.engine.stop()
            try await rig.render(2048)
            #expect(fetcher.live == 0)
        }
    }
}

/// Counts up.
final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// 1 the first time.
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Lets tasks wait until somebody opens it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        toResume.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if ready { continuation.resume() }
        }
    }
}
