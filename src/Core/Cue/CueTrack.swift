// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The path a track of a CUE sheet has in a playlist: `/path/to/album.cue:3`, the sheet and the number of the track in
/// it (see `CueSheet.resolve` for which number). Not a file that exists; it only has to be unique and tell where the
/// track comes from.
enum CuePath {
    static func make(sheet: String, number: Int) -> String {
        "\(sheet):\(number)"
    }

    /// The sheet and the number if `path` is such a path.
    static func parse(_ path: String) -> (sheet: String, number: Int)? {
        guard let colon = path.lastIndex(of: ":") else { return nil }
        let sheet = String(path[..<colon])
        let digits = path[path.index(after: colon)...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits),
              sheet.count > 4, sheet.lowercased().hasSuffix(".cue") else { return nil }
        return (sheet, number)
    }

    static func isCuePath(_ path: String) -> Bool {
        parse(path) != nil
    }
}

/// Where a playlist track that is a part of a bigger audio file lives: the track of a CUE sheet.
struct CueSlice: Equatable, Hashable, Sendable {
    /// Path of the `.cue` file.
    let sheet: String
    /// The number in the track's path (`CuePath`).
    let number: Int
    /// Path of the audio file the track is cut from.
    let file: String
    /// Seconds into the file where the track starts.
    let start: TimeInterval
    /// Seconds into the file where it ends; `nil` = at the end of the file.
    let end: TimeInterval?

    /// The pseudo path the track is stored under.
    var path: String { CuePath.make(sheet: sheet, number: number) }
    var sheetURL: URL { URL(fileURLWithPath: sheet, isDirectory: false) }
    var fileURL: URL { URL(fileURLWithPath: file, isDirectory: false) }
    /// Length of the track if the sheet says (the last track of a file has to ask the file).
    var duration: TimeInterval? { end.map { $0 - start } }
}

/// One playable track of a sheet, with what the sheet says about it.
struct CueTrack: Equatable, Sendable {
    let sheet: URL
    /// The number in the path of the track (see `CuePath`).
    let pathNumber: Int
    /// The `TRACK` number, which is the track number shown.
    let trackNumber: Int
    let audio: URL
    let start: TimeInterval
    let end: TimeInterval?
    let title: String?
    /// The track's own `PERFORMER`.
    let artist: String?
    /// The sheet's `PERFORMER`, for tracks that have none.
    let albumArtist: String?
    let album: String?
    let year: String?
    /// How many playable tracks the sheet has in this track's audio file (itself included).
    var fileTrackCount = 1

    /// Whether the sheet *cuts* its file: the file holds several tracks, or this track leaves a part of the file out
    /// (it starts after the beginning, e.g. to skip a pregap). Then the sheet is the source of truth for the track.
    /// A track that is its whole file doesn't need the sheet for anything: the sheet merely lists the file, like a
    /// playlist, and what the file says about itself comes first.
    var cutsFile: Bool { fileTrackCount > 1 || start > 0 || end != nil }

    var slice: CueSlice {
        CueSlice(sheet: sheet.path, number: pathNumber, file: audio.path, start: start, end: end)
    }

    /// The pseudo path as a URL (its directory is the sheet's).
    var url: URL { URL(fileURLWithPath: slice.path, isDirectory: false) }

    /// What a track becomes when it is imported: a part of the audio file (`tagResult`) if the sheet cuts the file,
    /// else the plain file itself (`plainResult`), which the sheet only helps with the tags it lacks.
    func importResult(id: Int, from file: TagReadResult) -> TagReadResult {
        cutsFile ? tagResult(id: id, from: file) : plainResult(id: id, from: file)
    }

    /// The tags of this track, field by field out of the sheet and the tags of the audio file (`file`):
    /// - the sheet cuts the file: the sheet's values come first, whatever it lacks is taken from the file. The file's
    ///   title and lyrics are only the track's if it is the only one in the file; the track number is always the
    ///   sheet's `TRACK`.
    /// - the sheet doesn't cut it: the file's values come first, the sheet fills in what the file lacks.
    /// A value that is blank counts as missing. The artist is the track's `PERFORMER`, else the sheet's.
    private func mergedTags(with file: TagReadResult) -> RawTags {
        let fields = file.rawFields
        let sheetArtist = artist ?? albumArtist
        let fileArtist = TagReader.artist(in: fields)
        let ownsFile = fileTrackCount == 1
        var raw = RawTags()

        func put(_ field: TagField, _ first: String?, _ second: String?) {
            raw.set(field, first ?? "")
            raw.set(field, second ?? "")
        }

        if cutsFile {
            put(.title, title, ownsFile ? fields[.title] : nil)
            put(.artist, sheetArtist, fileArtist)
            put(.album, album, fields[.album])
            put(.year, year, fields[.year])
            put(.track, String(trackNumber), nil)
            if ownsFile { put(.lyrics, fields[.lyrics], nil) }
        } else {
            put(.title, fields[.title], title)
            put(.artist, fileArtist, sheetArtist)
            put(.album, fields[.album], album)
            put(.year, fields[.year], year)
            put(.track, fields[.track], String(trackNumber))
            put(.lyrics, fields[.lyrics], nil)
        }
        return raw
    }

    /// The track as the plain audio file: its own path and tags (see `mergedTags`), no part of it, no sheet in its
    /// identity. A file that can't be read is the file's failure as it is.
    func plainResult(id: Int, from file: TagReadResult) -> TagReadResult {
        if case .failed = file.status { return file.with(id: id) }
        var raw = mergedTags(with: file)
        raw.duration = file.tags.duration
        let (tags, status) = TagReader.finalize(raw: raw, failed: nil)
        return TagReadResult(id: id, url: file.url, tags: tags, status: status, sources: file.sources, elapsed: file.elapsed,
                             rawFields: raw.fields, artwork: file.artwork, codec: file.codec)
    }

    /// The tag result of this track as a part of its audio file, with the pseudo path of the sheet's track (what
    /// reloading a track that is in a playlist yields, whether the sheet cuts the file or not). The values are merged
    /// as described at `mergedTags`, through the usual rules for missing tags: "Unknown Artist", "Unknown Track",
    /// "Unknown Album". What reading the audio file found gives the length of the last track, the artwork, and
    /// whether the file can be read at all. A track with no tags at all is still a track.
    func tagResult(id: Int, from file: TagReadResult) -> TagReadResult {
        var raw = mergedTags(with: file)
        if let end {
            raw.duration = end - start
        } else if let total = file.tags.duration, total > start {
            raw.duration = total - start
        }

        var failure: String?
        if case .failed(let reason) = file.status { failure = "\(audio.lastPathComponent): \(reason)" }
        let (tags, finalStatus) = TagReader.finalize(raw: raw, failed: failure)
        let status: TagReadStatus = finalStatus == .noTags ? .partial(fallbacks: ["title", "artist", "album"]) : finalStatus

        // Folder images are looked up next to the sheet, where the album is shown; the ones found next to an audio file
        // in another directory don't count.
        var artwork = file.artwork
        let sameDirectory = audio.deletingLastPathComponent().standardizedFileURL.path
            == sheet.deletingLastPathComponent().standardizedFileURL.path
        if !sameDirectory {
            if case .embedded = artwork {} else { artwork = .none }
        }

        return TagReadResult(id: id, url: url, tags: tags, status: status, sources: ["CUE"] + file.sources,
                             elapsed: file.elapsed, rawFields: raw.fields, artwork: artwork, codec: file.codec, cue: slice)
    }
}
