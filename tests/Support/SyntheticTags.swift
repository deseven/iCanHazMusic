// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Hand-built tag blocks and containers, for tests that don't need real audio.
enum Synthetic {
    /// Stand-in for MPEG audio: doesn't start with `ID3` and isn't parsed by anything that looks at the tail.
    static func audio(_ count: Int = 2000) -> Data {
        Data(repeating: 0xFF, count: count)
    }

    // MARK: MP3 trailers

    /// 128 byte ID3v1 tag.
    static func id3v1(title: String, artist: String, album: String, year: String = "2001", track: UInt8 = 4) -> Data {
        var d = Data.ascii("TAG")
        d += .fixed(title, 30)
        d += .fixed(artist, 30)
        d += .fixed(album, 30)
        d += .fixed(year, 4)
        d += Data(repeating: 0, count: 28)
        d += Data([0, track, 255])
        precondition(d.count == 128)
        return d
    }

    /// Lyrics3v2 block: `LYRICSBEGIN` + fields (id + 5 digit size + data) + 6 digit size + `LYRICS200`.
    static func lyrics3(_ fields: [(String, Data)]) -> Data {
        var block = Data.ascii("LYRICSBEGIN")
        for (id, value) in fields {
            block += .ascii(id) + .ascii(String(format: "%05d", value.count)) + value
        }
        return block + .ascii(String(format: "%06d", block.count)) + .ascii("LYRICS200")
    }

    static func lyrics3(_ fields: [(String, String)]) -> Data {
        lyrics3(fields.map { ($0.0, Data($0.1.utf8)) })
    }

    /// APEv2 tag: optional header, items, footer. `flags` of an item: 0 = UTF-8 text, 2 = binary.
    static func ape(_ items: [(key: String, value: Data, flags: Int)], withHeader: Bool = false) -> Data {
        var body = Data()
        for item in items {
            body += .le32(item.value.count) + .le32(item.flags) + Data(item.key.utf8) + Data([0]) + item.value
        }
        func frame(flags: Int) -> Data {
            .ascii("APETAGEX") + .le32(2000) + .le32(body.count + 32) + .le32(items.count) + .le32(flags)
                + Data(repeating: 0, count: 8)
        }
        let headerFlag = 1 << 31
        let header = withHeader ? frame(flags: headerFlag | 1 << 29) : Data()
        return header + body + frame(flags: withHeader ? headerFlag : 0)
    }

    static func ape(_ items: [(String, String)], withHeader: Bool = false) -> Data {
        ape(items.map { ($0.0, Data($0.1.utf8), 0) }, withHeader: withHeader)
    }

    // MARK: FLAC

    /// A FLAC `PICTURE` block body.
    static func pictureBlock(type: Int = 3, mime: String = "image/png", image: Data) -> Data {
        .be32(type) + .be32(mime.utf8.count) + .ascii(mime) + .be32(0)
            + .be32(10) + .be32(10) + .be32(24) + .be32(0) + .be32(image.count) + image
    }

    /// `fLaC` + metadata blocks (type, body). A STREAMINFO block is always first; the last block gets the flag.
    static func flac(blocks: [(type: Int, body: Data)], idv2Prefix: Bool = false) -> Data {
        var all: [(type: Int, body: Data)] = [(0, Data(repeating: 0, count: 34))]
        all += blocks
        var d = Data()
        if idv2Prefix {
            // ID3v2.4 header with a 20 byte body: syncsafe size.
            d += Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 20]) + Data(repeating: 0, count: 20)
        }
        d += .ascii("fLaC")
        for (i, block) in all.enumerated() {
            let last = i == all.count - 1
            let length = block.body.count
            d += Data([UInt8(block.type) | (last ? 0x80 : 0), UInt8(length >> 16 & 255), UInt8(length >> 8 & 255), UInt8(length & 255)])
            d += block.body
        }
        return d
    }
}
