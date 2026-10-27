// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Identity of a track within its playlist: a positive number that stays with the track through everything that
/// happens to the playlist (regrouping, removing other tracks, reloading tags, ...) and is never reused, so the
/// same file added twice has two IDs. Only meaningful together with the playlist it belongs to.
///
/// `unassignedTrackID` is what a track coming from outside (an import) has until the playlist takes it in and
/// gives it a real one.
typealias TrackID = Int
let unassignedTrackID: TrackID = 0

/// One track as it is stored in a playlist file: flat, with everything the album grouping needs.
/// This is also the input of `AlbumBuilder`, so a fresh import and a loaded playlist go through
/// the same grouping.
///
/// Decoding is lenient: only `path` is required, everything else falls back to the values
/// the tag reader would have used (a missing `id` is `unassignedTrackID`, which the playlist fills in).
/// Optional values are omitted from the file when unknown.
///
/// A track of a CUE sheet has the pseudo path `/path/to/album.cue:3` (`CuePath`) and a `cue` object saying where its audio
/// is: `{"file": "/path/to/album.flac", "start": 215.4, "end": 430.1}` (`end` is missing for the last track of a file).
/// The two always come together; an entry with only one of them can't be played and is dropped when the file is read.
struct TrackEntry: Codable {
    var id: TrackID
    /// Full file path; for a track of a CUE sheet the pseudo path `sheet.cue:N` (see `CuePath`).
    var path: String
    var artist: String
    var album: String
    var title: String
    var trackNumber: Int?
    var year: String?
    /// Seconds.
    var duration: TimeInterval?
    /// Short format label: the upper-cased file extension until the track has been played once, then what
    /// `CodecLabel` makes of the file (e.g. "MP3 CBR 320k", "FLAC 24/96").
    var codec: String
    /// Set for a track of a CUE sheet: the audio file and the part of it that is this track.
    var cue: CueSlice?

    /// The file the audio is in (for a CUE track the audio file, not the sheet).
    var url: URL { cue?.fileURL ?? Self.url(forPath: path) }

    /// The directory the track is shown in: the one of the file, or of the sheet for a CUE track.
    var directory: URL { Self.url(forPath: path).deletingLastPathComponent() }

    /// `isDirectory:` is given on purpose: without it Foundation stats the file, which is slow on network shares.
    private static func url(forPath path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }

    init(id: TrackID = unassignedTrackID, path: String, artist: String, album: String, title: String,
         trackNumber: Int?, year: String?, duration: TimeInterval?, codec: String, cue: CueSlice? = nil) {
        self.id = id
        self.path = path
        self.artist = artist
        self.album = album
        self.title = title
        self.trackNumber = trackNumber
        self.year = year
        self.duration = duration
        self.codec = codec
        self.cue = cue
    }

    /// From a tag read result (the caller has already dropped unusable ones).
    init(result r: TagReadResult) {
        self.init(
            path: r.url.path,
            artist: r.tags.artist,
            album: r.tags.album,
            // A missing title is better shown as the file name than as "Unknown Track". (A track of a CUE sheet has
            // no file name of its own.)
            title: r.rawFields[.title] != nil || r.cue != nil ? r.tags.title : r.url.deletingPathExtension().lastPathComponent,
            trackNumber: r.tags.trackNumber,
            year: r.tags.year,
            duration: r.tags.duration,
            codec: r.codec ?? (r.cue?.fileURL ?? r.url).pathExtension.uppercased(),
            cue: r.cue
        )
    }

    init(album: Album, track: Track) {
        self.init(
            id: track.id,
            path: track.path,
            artist: track.artist,
            album: album.title,
            title: track.title,
            trackNumber: track.number,
            year: album.year,
            duration: track.duration,
            codec: track.codec,
            cue: track.cue
        )
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        guard !path.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "empty path")
        }
        let url = Self.url(forPath: path)

        let stored = try? c.decodeIfPresent(StoredCue.self, forKey: .cue)
        if let cuePath = CuePath.parse(path) {
            guard let stored else {
                throw DecodingError.dataCorruptedError(forKey: .cue, in: c, debugDescription: "a CUE track without its audio file")
            }
            cue = CueSlice(sheet: cuePath.sheet, number: cuePath.number, file: stored.file, start: stored.start, end: stored.end)
        } else {
            cue = nil
        }
        let fileURL = cue?.fileURL ?? url

        func string(_ key: CodingKeys) -> String? {
            guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
            return s
        }

        id = (try? c.decodeIfPresent(TrackID.self, forKey: .id)) ?? unassignedTrackID
        self.path = path
        artist = string(.artist) ?? TagFallback.artist
        album = string(.album) ?? TagFallback.album
        title = string(.title) ?? (cue != nil ? TagFallback.title : url.deletingPathExtension().lastPathComponent)
        trackNumber = try? c.decodeIfPresent(Int.self, forKey: .trackNumber)
        year = string(.year)
        duration = try? c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        codec = string(.codec) ?? fileURL.pathExtension.uppercased()
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, artist, album, title, trackNumber, year, duration, codec, cue
    }

    /// The `cue` object of the file (the sheet and the number are in the path).
    private struct StoredCue: Codable {
        var file: String
        var start: TimeInterval
        var end: TimeInterval?
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(codec, forKey: .codec)
        if let cue { try c.encode(StoredCue(file: cue.file, start: cue.start, end: cue.end), forKey: .cue) }
    }
}

extension Album {
    /// The album's tracks as flat entries.
    var entries: [TrackEntry] {
        tracks.map { TrackEntry(album: self, track: $0) }
    }
}
