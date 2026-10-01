import Foundation
import Observation

/// One "add files to the playlist" run: gather the file list, read the tags, build the albums.
/// Progress is published for the UI. Foundation only, the UI observes it and calls `abort()`.
@MainActor
@Observable
final class ImportSession {
    enum Stage {
        case gathering   // recursive directory walk
        case reading     // tag parsing
        case appending   // building albums / adding them to the playlist
    }

    struct Outcome {
        /// Albums in playlist order, ready to be appended.
        let albums: [Album]
        /// How many supported files were found (0 = nothing to do).
        let fileCount: Int
        let aborted: Bool
    }

    /// Files read in parallel. Local disks saturate early; network shares keep scaling up to about this.
    private static let readConcurrency = 16

    private(set) var stage: Stage = .gathering
    private(set) var total = 0
    private(set) var processed = 0
    /// All of artist, album, year and track number present.
    private(set) var successful = 0
    /// Readable, but at least one of artist, album, year or track number is missing.
    private(set) var incomplete = 0
    /// No tags at all, or the file couldn't be read.
    private(set) var failed = 0
    private(set) var isAborting = false

    @ObservationIgnored private var readingStartedAt: Date?
    @ObservationIgnored private var readingFinishedAt: Date?
    @ObservationIgnored private var gatherTask: Task<[URL], Never>?
    @ObservationIgnored private var readTask: Task<[TagReadResult], Never>?

    /// Files processed per second since reading started (frozen once reading is over).
    func speed(at now: Date) -> Double {
        guard let start = readingStartedAt else { return 0 }
        let elapsed = (readingFinishedAt ?? now).timeIntervalSince(start)
        return elapsed > 0 ? Double(processed) / elapsed : 0
    }

    /// Stops what is going on and discards everything read so far: an aborted run yields no albums.
    func abort() {
        guard !isAborting, stage != .appending else { return }
        isAborting = true
        gatherTask?.cancel()
        readTask?.cancel()
    }

    func run(inputs: [URL]) async -> Outcome {
        // 1. Gather
        let gather = Task.detached(priority: .userInitiated) { AudioFileGatherer.gather(from: inputs) }
        gatherTask = gather
        let files = await gather.value
        gatherTask = nil

        total = files.count
        if isAborting || files.isEmpty {
            return Outcome(albums: [], fileCount: files.count, aborted: isAborting)
        }

        // 2. Read tags
        stage = .reading
        readingStartedAt = Date()
        let reader = TagReader(strategy: .auto, concurrency: Self.readConcurrency)
        let read = Task { () -> [TagReadResult] in
            var results: [TagReadResult?] = Array(repeating: nil, count: files.count)
            for await result in reader.read(urls: files) {
                if Task.isCancelled { break }
                results[result.id] = result
                record(result)
            }
            return results.compactMap { $0 }   // back to playlist order, gaps = aborted
        }
        readTask = read
        let results = await read.value
        readTask = nil
        readingFinishedAt = Date()

        if isAborting {
            return Outcome(albums: [], fileCount: files.count, aborted: true)
        }

        // 3. Albums
        stage = .appending
        let albums = await Task.detached(priority: .userInitiated) { AlbumBuilder.build(from: results) }.value
        Log.info("import: \(processed)/\(total) files read (\(successful) ok, \(incomplete) incomplete, \(failed) failed), \(albums.count) albums")
        return Outcome(albums: albums, fileCount: files.count, aborted: isAborting)
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
