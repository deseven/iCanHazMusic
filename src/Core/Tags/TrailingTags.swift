// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Tags stored at the *end* of an MP3, which neither AudioToolbox nor AVFoundation look at.
///
/// ID3v1 can't hold more than 30 bytes per title/artist/album, so old files tagged by tools that wrote
/// ID3v1 only often carry the full values in a Lyrics3v2 or APEv2 block right before it:
///
///     audio | [Lyrics3v2] | [APEv2] | [ID3v1, 128 bytes]
///
/// Only used for files without an ID3v2 header whose v1 values look cut off (see `RawTags.mayBeTruncatedV1`).
enum TrailingTags {
    private static let v1Size: UInt64 = 128
    private static let maxBlockSize: UInt64 = 2_000_000   // lyrics can be long, anything beyond this is not worth it

    /// Blocking. Returns the title/artist/album found in trailing Lyrics3v2/APEv2 blocks (possibly empty).
    static func read(url: URL) throws -> [TagField: String] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        // ID3v2 wins when present; nothing to recover then.
        guard let head = try fh.read(upToCount: 3), head != Data("ID3".utf8) else { return [:] }

        var end = try fh.seekToEnd()
        guard end > v1Size else { return [:] }
        if let tag = try TagBytes.read(fh, at: end - v1Size, count: 3), tag == Data("TAG".utf8) { end -= v1Size }

        var found: [TagField: String] = [:]
        for _ in 0..<3 {   // Lyrics3 and APE can follow each other in either order
            if let (fields, start) = try lyrics3(fh, end: end) {
                found.merge(fields) { current, _ in current }
                end = start
            } else if let (fields, start) = try ape(fh, end: end) {
                found.merge(fields) { current, _ in current }
                end = start
            } else {
                break
            }
        }
        return found
    }

    /// Whether an APEv2 footer sits directly in front of an ID3v1 tag at the end of the file. AVFoundation
    /// mistakes the `TAG` inside `APETAGEX` for the ID3v1 marker and returns garbage fields for such files,
    /// while AudioToolbox reads them correctly. Blocking, reads 160 bytes.
    static func hasApeBeforeV1(url: URL) throws -> Bool {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let end = try fh.seekToEnd()
        let tail = v1Size + 32
        guard end >= tail, let data = try TagBytes.read(fh, at: end - tail, count: Int(tail)) else { return false }
        return data.prefix(8) == Data("APETAGEX".utf8) && data.dropFirst(32).prefix(3) == Data("TAG".utf8)
    }

    // MARK: Lyrics3v2

    /// `LYRICSBEGIN` + fields (`ID` + 5 digit size + data) + 6 digit size + `LYRICS200`; the size covers the
    /// fields plus `LYRICSBEGIN`. Returns the fields and the offset where the block starts.
    private static func lyrics3(_ fh: FileHandle, end: UInt64) throws -> ([TagField: String], UInt64)? {
        guard end > 15, let trailer = try TagBytes.read(fh, at: end - 15, count: 15),
              trailer.suffix(9) == Data("LYRICS200".utf8),
              let size = UInt64(String(decoding: trailer.prefix(6), as: UTF8.self)),
              size >= 11, size <= maxBlockSize, size + 15 <= end,
              let block = try TagBytes.read(fh, at: end - 15 - size, count: Int(size)),
              block.prefix(11) == Data("LYRICSBEGIN".utf8)
        else { return nil }

        var fields: [TagField: String] = [:]
        var i = block.startIndex + 11
        while i + 8 <= block.endIndex {
            let id = String(decoding: block[i..<(i + 3)], as: UTF8.self)
            guard let length = Int(String(decoding: block[(i + 3)..<(i + 8)], as: UTF8.self)),
                  i + 8 + length <= block.endIndex else { break }
            let field: TagField? = switch id {
            case "ETT": .title
            case "EAR": .artist
            case "EAL": .album
            default: nil
            }
            if let field, let text = TagBytes.text(block[(i + 8)..<(i + 8 + length)]) { fields[field] = text }
            i += 8 + length
        }
        return (fields, end - 15 - size)
    }

    // MARK: APEv2

    /// The title, artist and album of the APEv2 tag that ends at `end` (see `ApeTag`: the footer is looked for there), and
    /// the offset where the tag starts.
    private static func ape(_ fh: FileHandle, end: UInt64) throws -> ([TagField: String], UInt64)? {
        guard let tag = try ApeTag.read(fh, end: end, maxSize: maxBlockSize) else { return nil }
        var fields: [TagField: String] = [:]
        for item in tag.items where item.kind == .text {   // text items only
            let field: TagField? = switch item.lowercasedKey {
            case "title": .title
            case "artist": .artist
            case "album": .album
            default: nil
            }
            // Multiple values are NUL separated, the first one is enough.
            if let field, let value = item.text, let text = TagBytes.text(value.prefix(while: { $0 != 0 })) { fields[field] = text }
        }
        return (fields, tag.start)
    }
}

extension RawTags {
    /// ID3v1 fields are 30 bytes at most, so a title/artist/album of that size is suspect.
    var mayBeTruncatedV1: Bool {
        [TagField.title, .artist, .album].contains { (fields[$0]?.utf8.count ?? 0) >= 30 }
    }

    /// Replaces values that are a cut-off start of the longer `recovered` one (never anything else).
    mutating func restoreTruncated(from recovered: [TagField: String]) {
        for field in [TagField.title, .artist, .album] {
            guard let long = recovered[field] else { continue }
            if let current = fields[field] {
                if long.count > current.count, long.lowercased().hasPrefix(current.lowercased()) { fields[field] = long }
            } else {
                fields[field] = long
            }
        }
    }
}
