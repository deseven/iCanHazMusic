// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Where one album's art may come from, in priority order (see `ArtworkSource`).
struct AlbumArtJob: Sendable {
    enum Candidate: Sendable {
        /// An image file in the album's folder.
        case file(URL)
        /// The artwork inside this audio file.
        case embedded(URL)
    }

    /// `AlbumKey` of the album, also the key in the cover cache.
    let key: String
    /// Tried in order, the first one that yields a decodable image wins. Empty = the album has no art.
    let candidates: [Candidate]
}

/// Finds, shrinks and caches the art of one album, once per album however many of its files carry the same
/// embedded picture.
enum AlbumArtProcessor {
    /// How many files of an album are tried for embedded art before giving up on it.
    private static let maxEmbeddedAttempts = 3
    private static let timeout: TimeInterval = 30

    /// One job per album of a directory. `results` must be *all* tag results of that directory's files (any order);
    /// the albums are the same ones `AlbumBuilder` makes out of them. Unusable files take no part.
    static func jobs(directory: URL, results: [TagReadResult]) -> [AlbumArtJob] {
        var order: [String] = []
        var groups: [String: [TagReadResult]] = [:]
        for result in results.sorted(by: { $0.id < $1.id }) where AlbumBuilder.isUsable(result.status) {
            let key = AlbumKey.make(directory: directory, title: result.tags.album)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(result)
        }
        return order.map { AlbumArtJob(key: $0, candidates: candidates(of: groups[$0]!, directory: directory)) }
    }

    private static func candidates(of tracks: [TagReadResult], directory: URL) -> [AlbumArtJob.Candidate] {
        func file(_ name: String) -> AlbumArtJob.Candidate { .file(directory.appendingPathComponent(name, isDirectory: false)) }

        // Folder images are the same for every file of the folder, so the first hit is enough.
        var cover: String?, anyImage: String?
        var embedded: [URL] = []
        for track in tracks {
            switch track.artwork {
            case .cover(let name): if cover == nil { cover = name }
            case .anyImage(let name): if anyImage == nil { anyImage = name }
            case .embedded: if embedded.count < maxEmbeddedAttempts { embedded.append(track.url) }
            case .none: break
            }
        }

        var out: [AlbumArtJob.Candidate] = []
        if let cover { out.append(file(cover)) }
        out += embedded.map { .embedded($0) }
        if let anyImage { out.append(file(anyImage)) }
        return out
    }

    /// Caches the thumbnail of the album. Returns whether one was found. Blocking work is offloaded, so many of
    /// these can be awaited concurrently.
    static func process(_ job: AlbumArtJob, into store: CoverStore = .shared) async -> Bool {
        let pixels = AppConstants.coverThumbnailPixels
        for candidate in job.candidates {
            if Task.isCancelled { return false }
            guard let image = await load(candidate) else { continue }
            guard let thumbnail = Thumbnailer.thumbnail(from: image, pixels: pixels) else {
                Log.error("album art: can't decode \(describe(candidate))")
                continue
            }
            store.store(thumbnail, for: job.key)
            return true
        }
        return false
    }

    /// The original image bytes of a candidate (nil = nothing there / unreadable).
    static func load(_ candidate: AlbumArtJob.Candidate) async -> Data? {
        switch candidate {
        case .file(let url):
            return try? await TagReader.offload(timeout: timeout) { try Data(contentsOf: url, options: .mappedIfSafe) }
        case .embedded(let url):
            if url.pathExtension.lowercased() == "flac" {
                return (try? await TagReader.offload(timeout: timeout) { try FlacArtwork.readPicture(url: url) }) ?? nil
            }
            return await AVFoundationBackend.embeddedArtwork(url: url)
        }
    }

    private static func describe(_ candidate: AlbumArtJob.Candidate) -> String {
        switch candidate {
        case .file(let url): url.path
        case .embedded(let url): "embedded art of \(url.path)"
        }
    }
}
