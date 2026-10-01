import Foundation

/// Turns tag read results into album blocks.
///
/// Files belong to the same album only if they have the same album tag *and* live in the same
/// directory; the same album name in two directories gives two blocks. Blocks keep the order in
/// which their first file appears in the input, files inside a block keep the input order.
enum AlbumBuilder {
    static let variousArtists = "Various Artists"

    /// Rows with `.failed` / `.noTags` are skipped. `results` must already be in playlist order.
    static func build(from results: [TagReadResult]) -> [Album] {
        struct Group {
            var directory: URL
            var results: [TagReadResult] = []
        }
        var groups: [Group] = []
        var indexByKey: [String: Int] = [:]

        for result in results where isUsable(result.status) {
            let directory = result.url.deletingLastPathComponent()
            let key = directory.path + "\u{0}" + result.tags.album.lowercased()
            if let i = indexByKey[key] {
                groups[i].results.append(result)
            } else {
                indexByKey[key] = groups.count
                groups.append(Group(directory: directory, results: [result]))
            }
        }
        return groups.map { makeAlbum(directory: $0.directory, results: $0.results) }
    }

    static func isUsable(_ status: TagReadStatus) -> Bool {
        switch status {
        case .complete, .partial: true
        case .noTags, .failed: false
        }
    }

    private static func makeAlbum(directory: URL, results: [TagReadResult]) -> Album {
        let artists = Set(results.map(\.tags.artist))
        let multipleArtists = artists.count > 1
        let tracks = results.map { r in
            Track(
                url: r.url,
                number: r.tags.trackNumber,
                // A missing title is better shown as the file name than as "Unknown Track".
                title: r.rawFields[.title] != nil ? r.tags.title : r.url.deletingPathExtension().lastPathComponent,
                artist: r.tags.artist,
                duration: r.tags.duration,
                codec: r.url.pathExtension.uppercased()
            )
        }
        return Album(
            directory: directory,
            artist: multipleArtists ? variousArtists : results[0].tags.artist,
            title: results[0].tags.album,
            year: results.lazy.compactMap(\.tags.year).first,
            cover: cover(for: results, in: directory),
            hasMultipleArtists: multipleArtists,
            tracks: tracks
        )
    }

    /// Best cover over all tracks: a `cover`/`folder`/... image, then embedded art, then any other image.
    private static func cover(for results: [TagReadResult], in directory: URL) -> AlbumCover {
        func rank(_ source: ArtworkSource) -> Int {
            switch source {
            case .cover: 0
            case .embedded: 1
            case .anyImage: 2
            case .none: 3
            }
        }
        guard let best = results.min(by: { rank($0.artwork) < rank($1.artwork) }) else { return .none }
        switch best.artwork {
        case .cover(let name), .anyImage(let name): return .file(directory.appendingPathComponent(name))
        case .embedded: return .embedded(best.url)
        case .none: return .none
        }
    }
}
