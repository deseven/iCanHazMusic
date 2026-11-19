// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Canonical tag fields we care about. Every backend maps its native key names onto these.
enum TagField: String, CaseIterable, Sendable {
    case title, artist, albumArtist, performer, band, discogsArtist, composer
    case album, year, track
    /// Unsynchronised or LRC lyrics (ID3 `USLT`, Vorbis `LYRICS`, MP4 `©lyr`, ...). Can be long.
    case lyrics
}

/// What stands for a tag that is missing or unreadable.
///
/// **The data (tags, playlists, what is reported to scrobbling services and LRCLIB) holds an empty string for it, never
/// these texts.** They are for showing to the user only (`shown...`), so the playlist, the queue, notifications, the
/// Dock menu and so on say "Unknown Artist" while nothing outside is told so.
///
/// A tag that literally says one of these texts (some taggers write them) counts as missing (`stored...`), and so do
/// they in playlist files written before the data was kept empty.
enum TagFallback {
    static let artist = "Unknown Artist"
    static let title = "Unknown Track"
    static let album = "Unknown Album"

    // MARK: Data

    /// A track that has an artist and a title of its own, i.e. one that something outside (scrobbling services, LRCLIB)
    /// can be asked about. Works on the data (empty = missing), not on what is shown.
    static func isIdentified(artist: String, title: String) -> Bool {
        !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func storedArtist(_ text: String?) -> String { stored(text, placeholder: artist) }
    static func storedTitle(_ text: String?) -> String { stored(text, placeholder: title) }
    static func storedAlbum(_ text: String?) -> String { stored(text, placeholder: album) }

    /// `text` as the data keeps it: empty if it is missing, blank, or the placeholder of its field.
    private static func stored(_ text: String?, placeholder: String) -> String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != placeholder else { return "" }
        return text
    }

    // MARK: Showing

    static func shownArtist(_ artist: String) -> String {
        artist.isEmpty ? Self.artist : artist
    }

    static func shownAlbum(_ album: String) -> String {
        album.isEmpty ? Self.album : album
    }

    /// A track without a title is called by the name of its file (`file`: the audio file, nil for a track that is a
    /// part of one, which has no name of its own).
    static func shownTitle(_ title: String, file: URL?) -> String {
        guard title.isEmpty else { return title }
        guard let file else { return Self.title }
        let name = file.deletingPathExtension().lastPathComponent
        return name.isEmpty ? Self.title : name
    }
}

/// Final tags: what the file says. `title`/`artist`/`album` are empty when it says nothing (see `TagFallback`).
struct TrackTags: Sendable, Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var year: String?
    var trackNumber: Int?
    /// Seconds. From AudioFile ("approximate duration") or AVFoundation, whichever backend ran.
    var duration: TimeInterval?
    /// The lyrics embedded in the file (line breaks as `\n`), nil if it has none.
    var lyrics: String?

    init() {}
}

enum TagReadStatus: Sendable, Equatable {
    /// title, artist and album were all found.
    case complete
    /// Some of title/artist/album were missing and replaced by fallbacks (names listed).
    case partial(fallbacks: [String])
    /// File was readable but has no title/artist/album at all.
    case noTags
    /// File could not be read (unsupported, corrupt, I/O error, timeout). Reason attached.
    case failed(String)

    var isFailure: Bool { if case .failed = self { true } else { false } }
}

struct TagReadResult: Sendable, Identifiable {
    /// Index of the file in the input array.
    let id: Int
    let url: URL
    let tags: TrackTags
    let status: TagReadStatus
    /// Which backends contributed, e.g. ["AudioFile", "AVFoundation"].
    let sources: [String]
    /// Wall-clock time spent on this file.
    let elapsed: TimeInterval
    /// Raw (post-key-mapping, pre-fallback) values. Useful for diagnostics.
    let rawFields: [TagField: String]
    /// Detected album-art source (`.none` for failed files or when artwork detection is off).
    let artwork: ArtworkSource
    /// The format label (`CodecLabel`) of the file, if reading it already told: it does for the files macOS doesn't
    /// open (WavPack, APE), which are opened by their decoder. nil = the file extension stands for it until playback.
    var codec: String? = nil
    /// Set for the result of a track that is a part of a file cut by a CUE sheet (then `url` is the pseudo path
    /// `sheet.cue:N`, see `CuePath`, and the sheet's tags come first, see `CueTrack`).
    var cue: CueSlice? = nil

    /// The same result as the file number `id` of another list.
    func with(id: Int) -> TagReadResult {
        TagReadResult(id: id, url: url, tags: tags, status: status, sources: sources, elapsed: elapsed,
                      rawFields: rawFields, artwork: artwork, codec: codec, cue: cue)
    }
}

enum TagReadError: LocalizedError, Sendable {
    case unreadable(String)
    case timeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .unreadable(let s): s
        case .timeout(let t): "timed out after \(Int(t)) s"
        }
    }
}
