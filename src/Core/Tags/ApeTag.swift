// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// An APEv2 tag at the end of a file: the tag of WavPack and Monkey's Audio files, and one that old MP3 files carry too.
///
///     [header, 32 bytes, optional] | items | footer, 32 bytes
///
/// The footer (`APETAGEX`, version, size of items + footer, item count, flags, 8 reserved bytes) is what is looked for,
/// because it sits right at the end (before an ID3v1 tag, if there is one). An item is its value's size (u32 LE), its
/// flags (u32 LE; bits 1 and 2: 0 text in UTF-8, 1 binary, 2 a locator), its key (ASCII, NUL terminated) and the value.
///
/// Reading is light, whatever the images in the tag weigh: the items are walked one by one and the value of a text item
/// is read, that of anything else (a cover) is only noted down, to be read by whoever needs it (`value(of:from:)`).
struct ApeTag {
    enum Kind {
        case text, binary, locator
    }

    struct Item {
        /// As written; keys are case-insensitive (ffmpeg writes `title`, Monkey's Audio `Title`).
        let key: String
        let kind: Kind
        /// Where the value is in the file, and its size.
        let offset: UInt64
        let size: Int
        /// A text item's value, all of it, which may be several NUL separated ones; `nil` for the other kinds, or for a
        /// text that is too long to be one (`maxTextBytes`).
        let text: Data?

        var lowercasedKey: String { key.lowercased() }
    }

    let items: [Item]
    /// The offset of the tag's first byte (its header's, if it has one).
    let start: UInt64

    /// Text items that are longer than this are not read (lyrics are the longest there is).
    static let maxTextBytes = 4 << 20
    /// Tags bigger than this (a cover included) are not worth looking at.
    static let maxTagBytes: UInt64 = 128 << 20
    /// Images bigger than this are not worth the memory.
    static let maxImageBytes = 64 << 20
    private static let maxItems = 4096

    /// The tag whose footer ends at `end` (the end of the file, or the start of an ID3v1 tag that ends it), `nil` if there
    /// is none (or what is there doesn't add up). Blocking.
    static func read(_ fh: FileHandle, end: UInt64, maxSize: UInt64 = maxTagBytes) throws -> ApeTag? {
        guard end > 32, let footer = try TagBytes.read(fh, at: end - 32, count: 32),
              footer.prefix(8) == Data("APETAGEX".utf8) else { return nil }
        let tagSize = UInt64(TagBytes.le32(footer, 12))
        let itemCount = Int(TagBytes.le32(footer, 16))
        let hasHeader = TagBytes.le32(footer, 20) & (1 << 31) != 0
        guard tagSize >= 32, tagSize <= maxSize, tagSize <= end else { return nil }

        let itemsEnd = end - 32
        var position = end - tagSize
        var items: [Item] = []
        for _ in 0..<min(itemCount, maxItems) {
            // The two sizes, and a key of 255 characters at most.
            guard position + 10 <= itemsEnd,
                  let head = try TagBytes.read(fh, at: position, count: Int(min(itemsEnd - position, 8 + 256))),
                  let nul = head[8...].firstIndex(of: 0) else { break }
            let size = Int(TagBytes.le32(head, 0))
            let flags = TagBytes.le32(head, 4)
            let offset = position + UInt64(nul + 1)
            guard offset + UInt64(size) <= itemsEnd else { break }

            let kind: Kind = switch (flags >> 1) & 3 {
            case 0: .text
            case 2: .locator
            default: .binary
            }
            var text: Data?
            if kind == .text, size <= maxTextBytes {
                text = size == 0 ? Data() : try TagBytes.read(fh, at: offset, count: size)
            }
            items.append(Item(key: String(decoding: head[8..<nul], as: UTF8.self), kind: kind, offset: offset,
                              size: size, text: text))
            position = offset + UInt64(size)
        }
        return ApeTag(items: items, start: end - tagSize - (hasHeader ? 32 : 0))
    }

    /// The tag of a file: after the ID3v1 tag that may end it, whose fields come along (`nil` if there is none).
    static func read(_ fh: FileHandle) throws -> (tag: ApeTag?, id3v1: [TagField: String]?) {
        var end = try fh.seekToEnd()
        var id3v1: [TagField: String]?
        if end >= Id3v1.size, let block = try TagBytes.read(fh, at: end - Id3v1.size, count: Int(Id3v1.size)),
           let fields = Id3v1.fields(block) {
            id3v1 = fields
            end -= Id3v1.size
        }
        return (try read(fh, end: end), id3v1)
    }

    // MARK: Values

    /// The text items, by the field they stand for (`TagKeyMap`): the first value of an item that has several, the first
    /// item of a field that has several.
    var fields: [TagField: String] {
        var found: [TagField: String] = [:]
        for item in items where item.kind == .text {
            guard let field = TagKeyMap.table[item.lowercasedKey], found[field] == nil,
                  let data = item.text, let text = TagBytes.text(data.prefix(while: { $0 != 0 })) else { continue }
            found[field] = text
        }
        return found
    }

    /// The cover: `Cover Art (Front)`, else any other `Cover Art (...)`. Only if it holds something.
    var cover: Item? {
        let covers = items.filter { $0.lowercasedKey.hasPrefix("cover art") && $0.kind != .locator && $0.size > 0 }
        return covers.first { $0.lowercasedKey == "cover art (front)" } ?? covers.first
    }

    /// The bytes of an item's value, `nil` if there are too many (`maxImageBytes`). Blocking.
    func value(of item: Item, from fh: FileHandle) throws -> Data? {
        guard item.size <= Self.maxImageBytes else { return nil }
        return try TagBytes.read(fh, at: item.offset, count: item.size)
    }

    /// The image of a cover item's value: a file name, a NUL, then the image. (Some writers leave the name out.)
    static func image(inCover value: Data) -> Data? {
        let isImage = value.starts(with: [0xFF, 0xD8]) || value.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || value.starts(with: Data("GIF8".utf8))
        if isImage { return value }
        guard let nul = value.prefix(512).firstIndex(of: 0), nul + 1 < value.endIndex else { return nil }
        return Data(value[(nul + 1)...])
    }
}

/// An ID3v1 tag: the last 128 bytes of a file, `TAG` and fixed width Latin-1 fields. WavPack files may carry one instead
/// of an APEv2 tag (or next to it, after it).
enum Id3v1 {
    static let size: UInt64 = 128

    /// The fields of a tag; `nil` if `block` isn't one. Title, artist and album are 30 bytes at most.
    static func fields(_ block: Data) -> [TagField: String]? {
        let b = Data(block)
        guard b.count == Int(size), b.prefix(3) == Data("TAG".utf8) else { return nil }
        var found: [TagField: String] = [:]
        func put(_ field: TagField, _ range: Range<Int>) {
            let raw = b[range].prefix(while: { $0 != 0 })
            let text = (String(data: Data(raw), encoding: .isoLatin1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { found[field] = text }
        }
        put(.title, 3..<33)
        put(.artist, 33..<63)
        put(.album, 63..<93)
        put(.year, 93..<97)
        // v1.1: the comment is 28 bytes, then a zero and the track number.
        if b[125] == 0, b[126] != 0 { found[.track] = String(b[126]) }
        return found
    }
}

/// Reading and decoding the bytes of tags at the end of a file.
enum TagBytes {
    /// Exactly `count` bytes at `offset` (indices start at 0), `nil` if the file has fewer.
    static func read(_ fh: FileHandle, at offset: UInt64, count: Int) throws -> Data? {
        try fh.seek(toOffset: offset)
        guard let data = try fh.read(upToCount: count), data.count == count else { return nil }
        return Data(data)   // re-based, indices start at 0
    }

    static func le32(_ d: Data, _ offset: Int) -> UInt32 {
        let o = d.startIndex + offset
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    /// UTF-8 if valid, otherwise Latin-1 (what Lyrics3 and ID3v1 specify). Trimmed, `nil` when empty.
    static func text(_ data: Data) -> String? {
        let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return t.isEmpty ? nil : t
    }
}
