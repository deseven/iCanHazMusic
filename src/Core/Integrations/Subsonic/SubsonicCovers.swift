// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The covers of the albums of a Subsonic server, asked for only when something shows them: nothing is fetched when
/// tracks are added or a playlist is opened.
///
/// One cover per album and run does everything (`load`):
/// 1. the big picture (`originalSize`, which counts as the original) is kept as a file in
///    `.cache/subsonic/{connection id}/covers` (`SubsonicCoverCache`), and is what Now Playing shows;
/// 2. the thumbnail of the playlist's album block is made from it and put into the cover cache (`CoverStore`) under the
///    album's key, if it is missing or the picture is new.
///
/// Asked for by
/// - Now Playing, when an album starts (`original(for:)`), which fetches if the file isn't there (or is of an older cover)
///   and makes the thumbnail if there is none;
/// - an album block that is on screen (`ensureThumbnail(for:)`): nothing happens if the thumbnail is there; an album that was
///   dealt with since the app started (fetched, or the server couldn't give it) isn't tried again;
/// - Reload Tag(s), which asks the server again whatever there is (`reload`).
///
/// Whoever shows a cover that was just stored is told through `onThumbnailStored`. Work in flight is shared: the same album
/// is never fetched twice at once, and a caller that goes away (an album block scrolled out of sight) doesn't stop it.
@MainActor
final class SubsonicCovers {
    static let shared = SubsonicCovers(service: .shared, thumbnails: .shared)

    /// The size (pixels, longer side) the picture is asked for: more than the Now Playing block and the sheet that
    /// enlarges it show.
    nonisolated static let originalSize = 1200
    /// How many covers `reload` fetches at once.
    static let concurrency = 4

    /// Which cover of which album.
    struct Request: Sendable, Equatable {
        let connection: UUID
        /// The album on the server (the cover id for a song that has none): what the file on disk is kept under.
        let albumID: String
        /// What `getCoverArt` is asked for. It changes when the picture does.
        let art: String
        /// `Album.key`, what the thumbnail is kept under.
        let albumKey: String

        /// The cover of an album of a server, nil for any other album and for one that has no cover.
        init?(album: Album) {
            guard let ref = album.tracks.lazy.compactMap(\.subsonic).first(where: { $0.coverArt != nil }),
                  let art = ref.coverArt else { return nil }
            connection = ref.connection
            albumID = ref.albumID ?? art
            self.art = art
            albumKey = album.key
        }
    }

    private struct Outcome {
        var data: Data?
        var thumbnailStored = false
    }

    /// Told (with the album key) when a thumbnail was stored: what is remembered of the album's cover is out of date.
    var onThumbnailStored: ((String) -> Void)?

    private let service: SubsonicService
    private let thumbnails: CoverStore
    private let thumbnailPixels: Int
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    /// Albums (by key) that an album block needn't ask for again this run: they have a thumbnail, or were tried.
    private var settled = Set<String>()

    init(service: SubsonicService, thumbnails: CoverStore, thumbnailPixels: Int = AppConstants.coverThumbnailPixels) {
        self.service = service
        self.thumbnails = thumbnails
        self.thumbnailPixels = thumbnailPixels
    }

    // MARK: - Asking

    /// The original of the cover (from the file on disk, else from the server), for Now Playing. Makes the thumbnail too if
    /// the album has none. nil if the server doesn't have one and nothing was kept.
    func original(for request: Request) async -> Data? {
        await run(request, refresh: false).data
    }

    /// For an album block that is on screen: makes the thumbnail if the album has none (see the type's text). Returns whether
    /// one was stored by that, in which case the block should load it again.
    func ensureThumbnail(for request: Request) async -> Bool {
        let key = request.albumKey
        guard !settled.contains(key) else { return false }
        if inFlight[key] == nil {
            let thumbnails = thumbnails
            let exists = await Task.detached(priority: .userInitiated) { thumbnails.data(for: key) != nil }.value
            if exists {
                settled.insert(key)
                return false
            }
        }
        return await run(request, refresh: false).thumbnailStored
    }

    /// Asks the server for these covers again, whatever there is on disk, and makes the thumbnails anew. A cover the server
    /// can't give leaves what there is as it is.
    func reload(_ requests: [Request]) async {
        var iterator = requests.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            func startNext() {
                guard let next = iterator.next() else { return }
                group.addTask { @MainActor [self] in _ = await run(next, refresh: true) }
            }
            for _ in 0..<Self.concurrency { startNext() }
            while await group.next() != nil { startNext() }
        }
    }

    // MARK: - Internals

    private func run(_ request: Request, refresh: Bool) async -> Outcome {
        let key = request.albumKey
        if !refresh, let running = inFlight[key] { return await running.value }
        let task = Task { await load(request, refresh: refresh) }
        inFlight[key] = task
        let outcome = await task.value
        if inFlight[key] == task { inFlight[key] = nil }
        return outcome
    }

    private func load(_ request: Request, refresh: Bool) async -> Outcome {
        let key = request.albumKey
        defer { settled.insert(key) }
        guard let cover = await service.cover(connection: request.connection, album: request.albumID, id: request.art,
                                              size: Self.originalSize, refresh: refresh) else {
            Log.info("subsonic: no cover for album \(request.albumID) of \"\(service.displayName(of: request.connection))\"")
            return Outcome()
        }

        let thumbnails = thumbnails
        let pixels = thumbnailPixels
        let data = cover.data
        // A picture just given by the server is a new one (or the same): the thumbnail follows it. One made from what was on
        // disk is only worth making when there is none.
        let replace = cover.isFromServer
        let stored = await Task.detached(priority: .utility) { () -> Bool in
            guard replace || thumbnails.data(for: key) == nil,
                  let thumbnail = Thumbnailer.thumbnail(from: data, pixels: pixels) else { return false }
            thumbnails.store(thumbnail, for: key)
            return true
        }.value
        if stored { onThumbnailStored?(key) }
        return Outcome(data: data, thumbnailStored: stored)
    }
}
