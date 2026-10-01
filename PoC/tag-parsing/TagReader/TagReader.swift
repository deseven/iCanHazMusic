import Foundation

/// Reads tags for many files with bounded parallelism and streams results back as soon as each file is done.
///
///     let reader = TagReader(strategy: .auto)   // concurrency: physical cores / 2
///     for await result in reader.read(paths: paths) { ... }   // arrives in completion order, not input order
///
/// Every input yields exactly one result (unless the consumer cancels). Failures never throw:
/// they come back as `status == .failed(reason)` with fallback tags, so the UI can show/skip them.
public final class TagReader: Sendable {

    public enum Strategy: String, CaseIterable, Sendable, Identifiable {
        /// AudioToolbox only. Fastest / simplest; no album-artist/performer/band fallback.
        case audioFile
        /// AVFoundation only. Richest metadata, heaviest.
        case avFoundation
        /// AudioToolbox first; AVFoundation only when the artist is missing (to apply the artist fallback chain
        /// album_artist > performer > band > discogs > composer, same as the old ffprobe code) or AudioToolbox failed.
        case hybrid
        /// Pick the order per file, based on benchmark results: .mp3 -> AVFoundation first (about 2x faster
        /// than AudioFile for MP3 on a NAS), everything else -> AudioFile first (faster for FLAC). The other
        /// backend is still consulted if the first one yields no artist, so neither can lose tags silently.
        case auto

        public var id: String { rawValue }
    }

    /// Default parallelism: physical CPU cores / 2 (at least 1). `hw.physicalcpu` counts performance and
    /// efficiency cores alike; falls back to the logical count if the sysctl fails.
    public static let defaultConcurrency: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0) != 0 || cores < 1 {
            cores = Int32(ProcessInfo.processInfo.processorCount)
        }
        return max(1, Int(cores) / 2)
    }()

    public let strategy: Strategy
    /// Max files being read at the same time.
    public let concurrency: Int
    /// Timeout for the blocking AudioToolbox read (dead NAS, stalled mount, ...).
    public let timeout: TimeInterval
    /// Detect the album-art source (folder image / embedded / any image) for every file. Detection only, no
    /// image is read. Turn off for pure tag benchmarks.
    public let detectArtwork: Bool

    private let artworkCache: ArtworkDirectoryCache

    public init(strategy: Strategy = .auto, concurrency: Int = TagReader.defaultConcurrency, timeout: TimeInterval = 30,
                detectArtwork: Bool = true) {
        self.strategy = strategy
        self.concurrency = max(1, concurrency)
        self.timeout = timeout
        self.detectArtwork = detectArtwork
        self.artworkCache = ArtworkDirectoryCache(timeout: timeout)
    }

    // MARK: Public API

    public func read(paths: [String]) -> AsyncStream<TagReadResult> {
        read(urls: paths.map { URL(fileURLWithPath: $0) })
    }

    public func read(urls: [URL]) -> AsyncStream<TagReadResult> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: TagReadResult.self) { group in
                    var next = 0
                    // Sliding window: never more than `concurrency` files in flight.
                    while next < min(self.concurrency, urls.count) {
                        let (i, u) = (next, urls[next])
                        group.addTask { await self.readOne(index: i, url: u) }
                        next += 1
                    }
                    while let result = await group.next() {
                        continuation.yield(result)
                        if Task.isCancelled { group.cancelAll(); continue }
                        if next < urls.count {
                            let (i, u) = (next, urls[next])
                            group.addTask { await self.readOne(index: i, url: u) }
                            next += 1
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads a single file (used by `read`, also handy for tests).
    public func readOne(index: Int = 0, url: URL) async -> TagReadResult {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var raw = RawTags()
        var sources: [String] = []
        var errors: [String] = []
        let timeout = self.timeout

        func viaAudioFile() async -> Bool {
            do {
                let got = try await Self.offload(timeout: timeout) { try AudioFileBackend.read(url: url) }
                merge(got, from: "AudioFile")
                return true
            } catch { errors.append(error.localizedDescription); return false }
        }
        func viaAVFoundation(recordErrors: Bool = true) async -> Bool {
            do {
                merge(try await AVFoundationBackend.read(url: url), from: "AVFoundation")
                return true
            } catch { if recordErrors { errors.append(error.localizedDescription) }; return false }
        }
        /// Merges a backend result and only credits it as a source if it actually contributed something
        /// (so "via AudioFile+AVFoundation" means both had something to say, not that both were called).
        func merge(_ got: RawTags, from backend: String) {
            let hadDuration = raw.duration != nil
            raw.merge(got)
            if !got.fields.isEmpty || (got.duration != nil && !hadDuration) { sources.append(backend) }
        }

        // Folder lookup first: a cover/folder/album image makes embedded artwork irrelevant.
        let folder = detectArtwork
            ? await artworkCache.listing(for: url.deletingLastPathComponent()) : .empty

        var effective = strategy
        if effective == .auto {
            effective = url.pathExtension.lowercased() == "mp3" ? .avFoundation : .hybrid
        }

        switch effective {
        case .audioFile:
            _ = await viaAudioFile()
        case .avFoundation:
            _ = await viaAVFoundation()
        case .hybrid, .auto:
            if url.pathExtension.lowercased() == "mp3" {   // auto: AVFoundation first for MP3
                if await viaAVFoundation(recordErrors: false) {
                    if raw.fields[.artist] == nil { _ = await viaAudioFile() }
                } else {
                    _ = await viaAudioFile()
                }
            } else {
                if await viaAudioFile() {
                    if raw.fields[.artist] == nil { _ = await viaAVFoundation(recordErrors: false) }
                } else {
                    errors.removeAll()   // AudioFile failing is not fatal if AVFoundation copes
                    _ = await viaAVFoundation()
                }
            }
        }

        let failed = sources.isEmpty
        var artwork = ArtworkSource.none
        if detectArtwork, !failed {
            if let name = folder.preferred {
                artwork = .cover(name)
            } else {
                if await hasEmbeddedArtwork(url: url, known: raw.hasArtwork) { artwork = .embedded }
                else if let name = folder.anyImage { artwork = .anyImage(name) }
            }
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let (tags, status) = Self.finalize(raw: raw, failed: failed ? explainFailure(errors, url) : nil)
        return TagReadResult(id: index, url: url, tags: tags, status: status,
                             sources: sources, elapsed: elapsed, rawFields: raw.fields, artwork: artwork)
    }

    /// `known` is what the tag read already found out (nil = AVFoundation didn't run). FLAC pictures are invisible
    /// to both macOS APIs, so they are looked for in the file itself; everything else uses AVFoundation item keys.
    private func hasEmbeddedArtwork(url: URL, known: Bool?) async -> Bool {
        if known == true { return true }
        if url.pathExtension.lowercased() == "flac" {
            return (try? await Self.offload(timeout: timeout) { try FlacArtwork.hasPicture(url: url) }) ?? false
        }
        if let known { return known }
        return await AVFoundationBackend.hasEmbeddedArtwork(url: url) ?? false
    }

    /// Both APIs report a vanished file with an unhelpful message (AudioToolbox returns an undocumented
    /// `'wht?'` OSStatus, AVFoundation says "the operation could not be completed"), so the reason is
    /// classified here. Only runs when a read already failed, so it costs nothing for healthy files.
    private func explainFailure(_ errors: [String], _ url: URL) -> String {
        let detail = errors.isEmpty ? "unknown error" : errors.joined(separator: "; ")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !exists {
            return "file not found (moved, renamed, or volume unavailable?) - \(detail)"
        }
        if isDir.boolValue {
            return "not a file (a folder was passed) - \(detail)"
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if size == 0 { return "file is empty (0 bytes) - \(detail)" }
        if !Self.hasAudioHeader(url) { return "unrecognised header (not an audio file?) - \(detail)" }
        return detail
    }

    /// Cheap magic-byte check, only used to explain a failure. Catches misnamed files (e.g. an MP4 video
    /// saved as ".mp3") and files with a damaged container header.
    private static func hasAudioHeader(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return true }   // unknown -> don't claim
        defer { try? fh.close() }
        guard let h = try? fh.read(upToCount: 16), h.count >= 4 else { return true }
        let b = [UInt8](h)
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return true }               // "ID3" (mp3 tag)
        if b[0] == 0xFF, b[1] & 0xE0 == 0xE0 { return true }                      // MPEG audio frame sync
        if b[0] == 0x54, b[1] == 0x41, b[2] == 0x47 { return true }               // "TAG" (id3v1 only)
        if b[0..<4] == [0x66, 0x4C, 0x61, 0x43] { return true }                   // "fLaC"
        if b[0..<4] == [0x4F, 0x67, 0x67, 0x53] { return true }                   // "OggS"
        if b[0..<4] == [0x52, 0x49, 0x46, 0x46] { return true }                   // "RIFF" (wav)
        if b[0..<4] == [0x46, 0x4F, 0x52, 0x4D] { return true }                   // "FORM" (aiff)
        if b[0..<4] == [0x63, 0x61, 0x66, 0x66] { return true }                   // "caff"
        if b[4..<8] == [0x66, 0x74, 0x79, 0x70] { return true }                   // "?ftyp" (mp4/m4a/alac)
        return false
    }

    // MARK: Normalisation

    /// Applies artist fallback chain, year/track parsing and "Unknown ..." defaults.
    static func finalize(raw: RawTags, failed: String?) -> (TrackTags, TagReadStatus) {
        var tags = TrackTags()
        tags.duration = raw.duration

        if let failed {
            return (tags, .failed(failed.isEmpty ? "unknown error" : failed))
        }

        // Old ffprobe logic: if there is no artist, try these; the *last* non-empty one won there,
        // so effective priority is album_artist > performer > band > discogs_artist_list > composer.
        let artist = raw.fields[.artist]
            ?? raw.fields[.albumArtist] ?? raw.fields[.performer] ?? raw.fields[.band]
            ?? raw.fields[.discogsArtist] ?? raw.fields[.composer]

        var fallbacks: [String] = []
        if let t = raw.fields[.title] { tags.title = t } else { fallbacks.append("title") }
        if let a = artist { tags.artist = a } else { fallbacks.append("artist") }
        if let a = raw.fields[.album] { tags.album = a } else { fallbacks.append("album") }

        if let y = raw.fields[.year] {
            tags.year = y.range(of: #"\d{4}"#, options: .regularExpression).map { String(y[$0]) } ?? y
        }
        if let t = raw.fields[.track] {   // "3", "03", "3/12"
            tags.trackNumber = Int(t.prefix(while: \.isNumber))
        }

        let status: TagReadStatus =
            fallbacks.isEmpty ? .complete :
            fallbacks.count == 3 ? .noTags : .partial(fallbacks: fallbacks)
        return (tags, status)
    }

    // MARK: Blocking work off the cooperative pool

    private static let ioQueue = DispatchQueue(label: "TagReader.io", qos: .userInitiated, attributes: .concurrent)

    /// Runs blocking `work` on a GCD queue and gives up waiting after `timeout` (the blocking call itself
    /// can't be interrupted, but the reader's window slot is freed and the file is reported as failed).
    static func offload<T: Sendable>(timeout: TimeInterval,
                                             _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let once = Once(c)
            let timer = DispatchWorkItem { once.resume(with: .failure(TagReadError.timeout(timeout))) }
            once.timer = timer
            ioQueue.asyncAfter(deadline: .now() + timeout, execute: timer)
            ioQueue.async {
                once.resume(with: Result { try work() })
            }
        }
    }
}

/// Resumes a continuation exactly once (whichever of work / timeout finishes first) and cancels the timer.
private final class Once<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    var timer: DispatchWorkItem?
    init(_ c: CheckedContinuation<T, Error>) { continuation = c }
    func resume(with result: Result<T, Error>) {
        lock.lock(); let c = continuation; continuation = nil; let t = timer; timer = nil; lock.unlock()
        t?.cancel()
        c?.resume(with: result)
    }
}
