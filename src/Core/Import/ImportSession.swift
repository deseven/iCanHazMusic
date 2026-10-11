// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

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
        /// How many supported files and tracks of CUE sheets were found (0 = nothing to do).
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
    /// Files that have lyrics in their tags (those are put into the lyrics store).
    private(set) var lyricsFound = 0
    private(set) var isAborting = false

    @ObservationIgnored private let coverStore: CoverStore
    @ObservationIgnored private let lyricsStore: LyricsStore
    /// Files read in parallel.
    @ObservationIgnored private let tagParsingConcurrency: Int
    @ObservationIgnored private var readingStartedAt: Date?
    @ObservationIgnored private var readingFinishedAt: Date?
    @ObservationIgnored private var gatherTask: Task<[ReadInput], Never>?
    @ObservationIgnored private var readTask: Task<[TagReadResult], Never>?
    @ObservationIgnored private var artTask: Task<Void, Never>?

    /// `tagParsingConcurrency`: how many files are read at the same time (the app takes it from the settings,
    /// see `PlaylistStore.effectiveTagParsingConcurrency`).
    init(coverStore: CoverStore = .shared, lyricsStore: LyricsStore = .shared,
         tagParsingConcurrency: Int = TagReader.defaultConcurrency) {
        self.coverStore = coverStore
        self.lyricsStore = lyricsStore
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

    /// Imports files and directories. CUE sheets among them (or found in the directories) add their tracks, and the audio
    /// files they name are not added on their own (see `AudioFileGatherer.gatherInputs`). Whether a sheet's track is a
    /// part of its file or the plain file depends on whether the sheet cuts it (`CueTrack.importResult`).
    func run(inputs: [URL]) async -> Outcome {
        await run(flat: false) { AudioFileGatherer.gatherInputs(from: inputs) }
    }

    /// Imports the files listed in playlist files (`PlaylistExchange`), in the order of the playlists. The tags are
    /// read from the files; files that don't exist show up as failed. Every track is an album of its own, so a flat
    /// playlist keeps the order of the list (a grouped one regroups when it takes them in).
    func run(playlists: [URL]) async -> Outcome {
        await run(flat: true) { PlaylistExchange.audioFiles(in: playlists).map(ReadInput.file) }
    }

    /// Imports exactly these files, in this order, duplicates included (files without a supported extension are
    /// dropped; missing ones show up as failed). Every track is an album of its own, like `run(playlists:)`.
    func run(files: [URL]) async -> Outcome {
        await run(flat: true) { files.filter(AudioFileGatherer.isSupported).map(ReadInput.file) }
    }

    private func run(flat: Bool, gathering: @escaping @Sendable () -> [ReadInput]) async -> Outcome {
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
        Log.info("import: \(processed)/\(total) files read (\(successful) ok, \(incomplete) incomplete, \(failed) failed), \(albums.count) albums, art for \(artsProcessed)/\(albumsProcessed), lyrics in \(lyricsFound) files")
        return Outcome(albums: albums, fileCount: files.count, aborted: isAborting)
    }

    /// Reads the tags (and processes the art) of files that are in the playlist already. A track of a CUE sheet is given
    /// by its pseudo path (`CuePath`); the sheet is read again for it, and the track stays a part of its file.
    func reload(files: [URL]) async -> ReloadOutcome {
        total = files.count
        guard !files.isEmpty else { return ReloadOutcome(results: [], aborted: false) }
        let inputs = await Task.detached(priority: .userInitiated) { Self.reloadInputs(for: files) }.value
        guard let results = await read(inputs) else { return ReloadOutcome(results: [], aborted: true) }
        stage = .updating
        Log.info("reload: \(processed)/\(total) files read (\(successful) ok, \(incomplete) incomplete, \(failed) failed), art for \(artsProcessed)/\(albumsProcessed), lyrics in \(lyricsFound) files")
        return ReloadOutcome(results: results, aborted: false)
    }

    /// What reading the tags of these playlist entries means: a file is read, a track of a sheet is looked up in the
    /// sheet again (each sheet is read once).
    nonisolated static func reloadInputs(for files: [URL]) -> [ReadInput] {
        var sheets: [String: CueSheet.Contents] = [:]
        var unreadable = Set<String>()
        return files.map { url in
            guard let cue = CuePath.parse(url.path) else { return .file(url) }
            if sheets[cue.sheet] == nil, !unreadable.contains(cue.sheet) {
                if let contents = CueSheet.contents(of: URL(fileURLWithPath: cue.sheet, isDirectory: false)) {
                    sheets[cue.sheet] = contents
                } else {
                    unreadable.insert(cue.sheet)
                }
            }
            guard let contents = sheets[cue.sheet] else { return .unavailable(url, reason: "can't read the cue sheet") }
            guard let track = contents.tracks.first(where: { $0.pathNumber == cue.number }) else {
                return .unavailable(url, reason: "the track isn't in the cue sheet (any more)")
            }
            return .cuePart(track)
        }
    }

    /// Reads tags. As soon as all files of a directory are read, its albums are known and their art is
    /// processed (concurrently with the rest of the reading), once per album. Results are in the order of `inputs`;
    /// `nil` if aborted.
    ///
    /// Every audio file is read once, however many inputs need it (the tracks of a CUE sheet are cut from one file); the
    /// tracks' results are made of that read and the sheet.
    private func read(_ inputs: [ReadInput]) async -> [TagReadResult]? {
        stage = .reading
        readingStartedAt = Date()

        var audioFiles: [URL] = []
        var audioIndex: [String: Int] = [:]
        var dependents: [[Int]] = []   // per audio file: the inputs that need it
        for (i, input) in inputs.enumerated() {
            guard let url = input.audioURL else { continue }
            if let known = audioIndex[url.path] {
                dependents[known].append(i)
            } else {
                audioIndex[url.path] = audioFiles.count
                audioFiles.append(url)
                dependents.append([i])
            }
        }

        Log.info("reading tags of \(audioFiles.count) files for \(inputs.count) tracks, \(tagParsingConcurrency) at a time")
        let reader = TagReader(strategy: .auto, concurrency: tagParsingConcurrency)
        let (artJobs, artFeed) = AsyncStream<AlbumArtJob>.makeStream()
        let art = Task { await processArt(artJobs) }
        artTask = art

        let read = Task { () -> [TagReadResult] in
            var unread = Dictionary(grouping: inputs, by: { $0.resultURL.deletingLastPathComponent().path }).mapValues(\.count)
            var results: [TagReadResult?] = Array(repeating: nil, count: inputs.count)
            var finishedFiles: [String: [TagReadResult]] = [:]

            @MainActor func accept(_ result: TagReadResult) {
                results[result.id] = result
                record(result)

                let directory = result.url.deletingLastPathComponent()
                finishedFiles[directory.path, default: []].append(result)
                unread[directory.path, default: 1] -= 1
                if unread[directory.path] == 0, let all = finishedFiles.removeValue(forKey: directory.path) {
                    for job in AlbumArtProcessor.jobs(directory: directory, results: all) { artFeed.yield(job) }
                }
            }

            for (i, input) in inputs.enumerated() {
                guard case .unavailable(let url, let reason) = input else { continue }
                accept(TagReadResult(id: i, url: url, tags: TrackTags(), status: .failed(reason), sources: [], elapsed: 0,
                                     rawFields: [:], artwork: .none))
            }
            for await file in reader.read(urls: audioFiles) {
                if Task.isCancelled { break }
                for i in dependents[file.id] {
                    switch inputs[i] {
                    case .file: accept(file.with(id: i))
                    case .cueTrack(let track): accept(track.importResult(id: i, from: file))
                    case .cuePart(let track): accept(track.tagResult(id: i, from: file))
                    case .unavailable: break
                    }
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

    /// The lyrics of the file are the source of truth: they replace what the store has for the track (also what
    /// LRCLIB brought). Tracks without tags have no identity to keep them under.
    private func recordLyrics(_ result: TagReadResult) {
        guard AlbumBuilder.isUsable(result.status), let text = result.tags.lyrics,
              let lyrics = Lyrics.embedded(text) else { return }
        let entry = TrackEntry(result: result)
        guard TagFallback.isIdentified(artist: entry.artist, title: entry.title) else { return }
        lyricsStore.store(lyrics, for: LyricsKey.make(artist: entry.artist, title: entry.title, album: entry.album))
        lyricsFound += 1
    }

    private func record(_ result: TagReadResult) {
        processed += 1
        recordLyrics(result)
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
