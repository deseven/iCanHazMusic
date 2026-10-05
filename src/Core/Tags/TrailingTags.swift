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
        if let tag = try bytes(fh, at: end - v1Size, count: 3), tag == Data("TAG".utf8) { end -= v1Size }

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
        guard end >= tail, let data = try bytes(fh, at: end - tail, count: Int(tail)) else { return false }
        return data.prefix(8) == Data("APETAGEX".utf8) && data.dropFirst(32).prefix(3) == Data("TAG".utf8)
    }

    // MARK: Lyrics3v2

    /// `LYRICSBEGIN` + fields (`ID` + 5 digit size + data) + 6 digit size + `LYRICS200`; the size covers the
    /// fields plus `LYRICSBEGIN`. Returns the fields and the offset where the block starts.
    private static func lyrics3(_ fh: FileHandle, end: UInt64) throws -> ([TagField: String], UInt64)? {
        guard end > 15, let trailer = try bytes(fh, at: end - 15, count: 15),
              trailer.suffix(9) == Data("LYRICS200".utf8),
              let size = UInt64(String(decoding: trailer.prefix(6), as: UTF8.self)),
              size >= 11, size <= maxBlockSize, size + 15 <= end,
              let block = try bytes(fh, at: end - 15 - size, count: Int(size)),
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
            if let field, let text = decode(block[(i + 8)..<(i + 8 + length)]) { fields[field] = text }
            i += 8 + length
        }
        return (fields, end - 15 - size)
    }

    // MARK: APEv2

    /// 32 byte footer `APETAGEX` (version, tag size incl. footer, item count, flags) preceded by the items.
    private static func ape(_ fh: FileHandle, end: UInt64) throws -> ([TagField: String], UInt64)? {
        guard end > 32, let footer = try bytes(fh, at: end - 32, count: 32),
              footer.prefix(8) == Data("APETAGEX".utf8) else { return nil }
        let tagSize = UInt64(le32(footer, 12))
        let itemCount = Int(le32(footer, 16))
        let hasHeader = le32(footer, 20) & (1 << 31) != 0
        guard tagSize >= 32, tagSize <= maxBlockSize, tagSize <= end,
              let items = try bytes(fh, at: end - tagSize, count: Int(tagSize) - 32) else { return nil }

        var fields: [TagField: String] = [:]
        var i = items.startIndex
        for _ in 0..<itemCount {
            guard i + 8 <= items.endIndex else { break }
            let valueSize = Int(le32(items, i - items.startIndex))
            let flags = le32(items, i - items.startIndex + 4)
            guard let nul = items[(i + 8)...].firstIndex(of: 0), nul + 1 + valueSize <= items.endIndex else { break }
            let key = String(decoding: items[(i + 8)..<nul], as: UTF8.self).lowercased()
            let value = items[(nul + 1)..<(nul + 1 + valueSize)]
            i = nul + 1 + valueSize
            guard (flags >> 1) & 3 == 0 else { continue }   // text items only
            let field: TagField? = switch key {
            case "title": .title
            case "artist": .artist
            case "album": .album
            default: nil
            }
            // Multiple values are NUL separated, the first one is enough.
            if let field, let text = decode(value.prefix(while: { $0 != 0 })) { fields[field] = text }
        }
        return (fields, end - tagSize - (hasHeader ? 32 : 0))
    }

    // MARK: Helpers

    private static func bytes(_ fh: FileHandle, at offset: UInt64, count: Int) throws -> Data? {
        try fh.seek(toOffset: offset)
        guard let data = try fh.read(upToCount: count), data.count == count else { return nil }
        return Data(data)   // re-based, indices start at 0
    }

    private static func le32(_ d: Data, _ offset: Int) -> UInt32 {
        let o = d.startIndex + offset
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    /// UTF-8 if valid, otherwise Latin-1 (what Lyrics3 specifies). Trimmed, `nil` when empty.
    private static func decode(_ data: Data) -> String? {
        let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return t.isEmpty ? nil : t
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
