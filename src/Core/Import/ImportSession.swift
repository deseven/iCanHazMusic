import Foundation
import Observation

/// One "add files to the playlist" run: gather the file list, read the tags, build the albums. Also used to read the
/// tags of files that are in the playlist already (`reload`). The album art is processed in both cases.
/// Progress is published for the UI. Foundation only, the UI observes it and calls `abort()`.
@MainActor
@Observable
final class ImportSession {
    enum Stage {
        case gathering   // recursive directory walk
        case reading     // tag parsing
        case appending   // building albums / adding them to the playlist
        case updating    // regrouping the playlist after reloading tags
    }

    /// Result of `reload`.
    struct ReloadOutcome {
        /// One per file (the unusable ones have a `.failed`/`.noTags` status), in the order of the input.
        let results: [TagReadResult]
        let aborted: Bool
    }

    struct Outcome {
        /// Albums in playlist order, ready to be appended.
        let albums: [Album]
        /// How many supported files were found (0 = nothing to do).
        let fileCount: Int
        let aborted: Bool
    }

    /// Albums whose art is decoded and shrunk at the same time (CPU bound, so far fewer than file reads).
    private static let artConcurrency = 4

    private(set) var stage: Stage = .gathering
    private(set) var total = 0
    private(set) var processed = 0
    /// All of artist, album, year and track number present.
    private(set) var successful = 0
    /// Readable, but at least one of artist, album, year or track number is missing.
    private(set) var incomplete = 0
    /// No tags at all, or the file couldn't be read.
    private(set) var failed = 0
    /// Albums that are completely read and had their art looked for.
    private(set) var albumsProcessed = 0
    /// Of those, albums whose art was found and put into the cover cache.
    private(set) var artsProcessed = 0
    private(set) var isAborting = false

    @ObservationIgnored private let coverStore: CoverStore
    /// Files read in parallel.
    @ObservationIgnored private let tagParsingConcurrency: Int
    @ObservationIgnored private var readingStartedAt: Date?
    @ObservationIgnored private var readingFinishedAt: Date?
    @ObservationIgnored private var gatherTask: Task<[URL], Never>?
    @ObservationIgnored private var readTask: Task<[TagReadResult], Never>?
    @ObservationIgnored private var artTask: Task<Void, Never>?

    /// `tagParsingConcurrency`: how many files are read at the same time (the app takes it from the settings,
    /// see `PlaylistStore.effectiveTagParsingConcurrency`).
    init(coverStore: CoverStore = .shared, tagParsingConcurrency: Int = TagReader.defaultConcurrency) {
        self.coverStore = coverStore
        self.tagParsingConcurrency = max(1, tagParsingConcurrency)
    }

    /// Everything is read, only the playlist is being put together: too late to abort.
    var isFinishing: Bool { stage == .appending || stage == .updating }

    /// Files processed per second since reading started (frozen once reading is over).
    func speed(at now: Date) -> Double {
        guard let start = readingStartedAt else { return 0 }
        let elapsed = (readingFinishedAt ?? now).timeIntervalSince(start)
        return elapsed > 0 ? Double(processed) / elapsed : 0
    }

    /// Stops what is going on and discards everything read so far: an aborted run yields no albums.
    func abort() {
        guard !isAborting, !isFinishing else { return }
        isAborting = true
        gatherTask?.cancel()
        readTask?.cancel()
        artTask?.cancel()
    }

    func run(inputs: [URL]) async -> Outcome {
        await run(flat: false) { AudioFileGatherer.gather(from: inputs) }
    }

    /// Imports the files listed in playlist files (`PlaylistExchange`), in the order of the playlists. The tags are
    /// read from the files; files that don't exist show up as failed. Every track is an album of its own, so a flat
    /// playlist keeps the order of the list (a grouped one regroups when it takes them in).
    func run(playlists: [URL]) async -> Outcome {
        await run(flat: true) { PlaylistExchange.audioFiles(in: playlists) }
    }

    private func run(flat: Bool, gathering: @escaping @Sendable () -> [URL]) async -> Outcome {
        // 1. Gather
        let gather = Task.detached(priority: .userInitiated) { gathering() }
        gatherTask = gather
        let files = await gather.value
        gatherTask = nil

        total = files.count
        if isAborting || files.isEmpty {
            return Outcome(albums: [], fileCount: files.count, aborted: isAborting)
        }

        // 2. Read tags and art
        guard let results = await read(files) else {
            return Outcome(albums: [], fileCount: files.count, aborted: true)
        }

        // 3. Albums. The playlist groups them (or not) itself when it takes them in; these are the same albums
        //    a grouped playlist would make.
        stage = .appending
        let albums = await Task.detached(priority: .userInitiated) { AlbumBuilder.build(from: results, flat: flat) }.value
        Log.info("import: \(processed)/\(total) files read (\(successful) ok, \(incomplete) incomplete, \(failed) failed), \(albums.count) albums, art for \(artsProcessed)/\(albumsProcessed)")
        return Outcome(albums: albums, fileCount: files.count, aborted: isAborting)
    }

    /// Reads the tags (and processes the art) of files that are in the playlist already.
    func reload(files: [URL]) async -> ReloadOutcome {
        total = files.count
        guard !files.isEmpty else { return ReloadOutcome(results: [], aborted: false) }
        guard let results = await read(files) else { return ReloadOutcome(results: [], aborted: true) }
        stage = .updating
        Log.info("reload: \(processed)/\(total) files read (\(successful) ok, \(incomplete) incomplete, \(failed) failed), art for \(artsProcessed)/\(albumsProcessed)")
        return ReloadOutcome(results: results, aborted: false)
    }

    /// Reads tags. As soon as all files of a directory are read, its albums are known and their art is
    /// processed (concurrently with the rest of the reading), once per album. Results are in the order of `files`;
    /// `nil` if aborted.
    private func read(_ files: [URL]) async -> [TagReadResult]? {
        stage = .reading
        readingStartedAt = Date()
        Log.info("reading tags of \(files.count) files, \(tagParsingConcurrency) at a time")
        let reader = TagReader(strategy: .auto, concurrency: tagParsingConcurrency)
        let (artJobs, artFeed) = AsyncStream<AlbumArtJob>.makeStream()
        let art = Task { await processArt(artJobs) }
        artTask = art

        let read = Task { () -> [TagReadResult] in
            var unread = Dictionary(grouping: files, by: { $0.deletingLastPathComponent().path }).mapValues(\.count)
            var results: [TagReadResult?] = Array(repeating: nil, count: files.count)
            var finishedFiles: [String: [TagReadResult]] = [:]
            for await result in reader.read(urls: files) {
                if Task.isCancelled { break }
                results[result.id] = result
                record(result)

                let directory = result.url.deletingLastPathComponent()
                finishedFiles[directory.path, default: []].append(result)
                unread[directory.path, default: 1] -= 1
                if unread[directory.path] == 0, let all = finishedFiles.removeValue(forKey: directory.path) {
                    for job in AlbumArtProcessor.jobs(directory: directory, results: all) { artFeed.yield(job) }
                }
            }
            artFeed.finish()
            return results.compactMap { $0 }   // back to playlist order, gaps = aborted
        }
        readTask = read
        let results = await read.value
        readTask = nil
        readingFinishedAt = Date()
        await art.value
        artTask = nil

        return isAborting ? nil : results
    }

    /// Processes the art of the albums as they come in, a few at a time.
    private func processArt(_ jobs: AsyncStream<AlbumArtJob>) async {
        await withTaskGroup(of: Bool.self) { group in
            var running = 0
            for await job in jobs {
                if Task.isCancelled { break }
                if running >= Self.artConcurrency, let found = await group.next() {
                    running -= 1
                    recordArt(found: found)
                }
                let store = coverStore
                group.addTask { await AlbumArtProcessor.process(job, into: store) }
                running += 1
            }
            while let found = await group.next() { recordArt(found: found) }
        }
    }

    private func recordArt(found: Bool) {
        albumsProcessed += 1
        if found { artsProcessed += 1 }
    }

    private func record(_ result: TagReadResult) {
        processed += 1
        switch result.status {
        case .failed(let reason):
            failed += 1
            Log.error("can't read \(result.url.path): \(reason)")
        case .noTags:
            failed += 1
            Log.error("no tags in \(result.url.path)")
        case .complete:
            classify(result, missing: [])
        case .partial(let fallbacks):
            classify(result, missing: fallbacks)
        }
    }

    private func classify(_ result: TagReadResult, missing: [String]) {
        let incompleteTags = missing.contains("artist") || missing.contains("album")
            || result.tags.year == nil || result.tags.trackNumber == nil
        if incompleteTags { incomplete += 1 } else { successful += 1 }
    }
}
