import Foundation
@testable import iCanHazMusic

/// Builders for playlist model values.
enum Make {
    static func entry(_ path: String, artist: String = "Artist", album: String = "Album", title: String? = nil,
                      track: Int? = nil, year: String? = nil, duration: TimeInterval? = nil, codec: String? = nil) -> TrackEntry {
        let url = URL(fileURLWithPath: path)
        return TrackEntry(
            path: path, artist: artist, album: album,
            title: title ?? url.deletingPathExtension().lastPathComponent,
            trackNumber: track, year: year, duration: duration,
            codec: codec ?? url.pathExtension.uppercased()
        )
    }

    /// `count` tracks `01.mp3` ... in `/Music/<dir>`, one album.
    static func entries(dir: String, album: String, artist: String = "Artist", count: Int, year: String? = nil) -> [TrackEntry] {
        (1...count).map { n in
            entry(String(format: "/Music/%@/%02d.mp3", dir, n), artist: artist, album: album, track: n, year: year, duration: 100)
        }
    }

    static func albums(_ entries: [TrackEntry]) -> [Album] {
        AlbumBuilder.build(from: entries)
    }

    static func playlist(_ entries: [TrackEntry]) -> Playlist {
        Playlist(albums: albums(entries))
    }

    static func result(_ path: String, id: Int = 0, status: TagReadStatus = .complete,
                       title: String? = "Title", artist: String = "Artist", album: String = "Album",
                       track: Int? = nil, duration: TimeInterval? = nil,
                       artwork: ArtworkSource = .none) -> TagReadResult {
        var tags = TrackTags()
        tags.artist = artist
        tags.album = album
        tags.trackNumber = track
        tags.duration = duration
        var raw: [TagField: String] = [:]
        if let title { tags.title = title; raw[.title] = title }
        return TagReadResult(id: id, url: URL(fileURLWithPath: path), tags: tags, status: status,
                             sources: ["test"], elapsed: 0, rawFields: raw, artwork: artwork)
    }
}
