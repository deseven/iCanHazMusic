import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Raw tag bag

/// Tags as extracted from one or more backends, keyed by canonical field. First non-empty value wins.
struct RawTags: Sendable {
    var fields: [TagField: String] = [:]
    var duration: TimeInterval?
    /// Whether the file carries embedded artwork. nil = not checked (backend didn't run / failed).
    var hasArtwork: Bool?

    mutating func set(_ field: TagField, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !v.isEmpty, fields[field] == nil else { return }
        fields[field] = v
    }

    /// Fills only what's still missing.
    mutating func merge(_ other: RawTags) {
        for (k, v) in other.fields where fields[k] == nil { fields[k] = v }
        if duration == nil { duration = other.duration }
        if let o = other.hasArtwork { hasArtwork = (hasArtwork ?? false) || o }
    }

}

// MARK: - Key mapping

enum TagKeyMap {
    /// Native key (lowercased, percent-decoded) -> canonical field.
    /// Covers ID3v2.2/2.3/2.4, Vorbis comments (FLAC/OGG), iTunes/MP4 atoms and CAF/WAV/AIFF info chunks.
    static let table: [String: TagField] = [
        // ID3v2
        "tit2": .title, "tt2": .title,
        "tpe1": .artist, "tp1": .artist,
        "tpe2": .albumArtist, "tp2": .albumArtist,        // "Band/orchestra" - de-facto album artist
        "tcom": .composer, "tcm": .composer,
        "talb": .album, "tal": .album,
        "tyer": .year, "tye": .year, "tdrc": .year,
        "trck": .track, "trk": .track,
        // Vorbis comments
        "title": .title, "artist": .artist,
        "albumartist": .albumArtist, "album artist": .albumArtist,
        "performer": .performer, "band": .band,
        "discogs_artist_list": .discogsArtist,
        "composer": .composer, "album": .album,
        "date": .year, "year": .year,
        "tracknumber": .track, "track": .track,
        // iTunes / MP4
        "©nam": .title, "©art": .artist, "aart": .albumArtist,
        "©wrt": .composer, "©alb": .album, "©day": .year, "trkn": .track,
        // Lyrics: ID3 USLT (v2.2: ULT), Vorbis comments, MP4 "©lyr", CAF/WAV/AIFF info chunk. The synchronised
        // ID3 SYLT frame is binary and not read.
        "uslt": .lyrics, "ult": .lyrics, "lyrics": .lyrics, "unsyncedlyrics": .lyrics,
        "©lyr": .lyrics, "info-lyrics": .lyrics,
        // CAF / WAV / AIFF info chunk (AVFoundation exposes them as "info-<key>")
        "info-title": .title, "info-artist": .artist, "info-album": .album,
        "info-album artist": .albumArtist, "info-composer": .composer,
        "info-date": .year, "info-year": .year, "info-track": .track,
    ]

    /// AudioFile info-dictionary keys -> canonical field.
    static let audioFileTable: [String: TagField] = [
        "title": .title, "artist": .artist, "album": .album, "composer": .composer,
        "year": .year, "recorded date": .year, "date": .year,
        "track number": .track, "track": .track,
        "lyrics": .lyrics,   // CAF only; for the other containers it is the other backends that find lyrics
    ]

    /// Splits a raw key like "id3/TPE1" or "itsk/%A9ART" into ("id3", "tpe1") / ("itsk", "©art").
    /// Keys without a prefix (AVFoundation exposes ID3v2.2 items - `TT2`, `TP1`, ... - as bare keys with
    /// `identifier == nil`) are returned with an empty prefix so they still map.
    static func parse(identifier: String) -> (prefix: String, key: String) {
        let prefix: String
        let rawKey: String
        if let slash = identifier.firstIndex(of: "/") {
            prefix = String(identifier[..<slash])
            rawKey = String(identifier[identifier.index(after: slash)...])
        } else {
            prefix = ""
            rawKey = identifier
        }
        // MP4 atom names start with the Latin-1 byte 0xA9 ("©"), which is a *lone* byte when percent-decoded
        // (invalid UTF-8) and makes removingPercentEncoding return nil - so handle it explicitly first.
        let decoded = rawKey
            .replacingOccurrences(of: "%A9", with: "©", options: .caseInsensitive)
        let key = (decoded.removingPercentEncoding ?? decoded).lowercased()
        return (prefix, key)
    }
}

// MARK: - AudioToolbox backend

/// `AudioFileOpenURL` + `kAudioFilePropertyInfoDictionary`. Synchronous, returns a *normalised* dictionary
/// (title/artist/album/year/track/composer) for every container we care about, plus a reliable duration.
/// It does NOT expose album-artist / performer / band.
enum AudioFileBackend {
    static func read(url: URL) throws -> RawTags {
        var file: AudioFileID?
        let st = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)
        guard st == noErr, let file else {
            throw TagReadError.unreadable("AudioFileOpenURL: \(describe(st))")
        }
        defer { AudioFileClose(file) }

        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var dict: Unmanaged<CFDictionary>?
        let st2 = AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &dict)
        guard st2 == noErr, let info = dict?.takeRetainedValue() as? [String: Any] else {
            throw TagReadError.unreadable("info dictionary: \(describe(st2))")
        }

        var raw = RawTags()
        for (k, v) in info {
            if k == "approximate duration in seconds" {
                if let d = (v as? NSNumber)?.doubleValue ?? Double("\(v)"), d > 0 { raw.duration = d }
            } else if let field = TagKeyMap.audioFileTable[k.lowercased()] {
                raw.set(field, stringify(v))
            }
        }
        return raw
    }

    private static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return "\(v)"
    }

    static func describe(_ status: OSStatus) -> String {
        switch status {
        case kAudioFileUnsupportedFileTypeError: return "unsupported file type"
        case kAudioFileUnsupportedDataFormatError: return "unsupported data format"
        case kAudioFileInvalidFileError: return "invalid or corrupt file"
        case kAudioFileNotOptimizedError: return "file not optimized"
        case kAudioFileFileNotFoundError: return "file not found"
        case kAudioFilePermissionsError: return "permission denied"
        // Undocumented status AudioToolbox returns when the path cannot be resolved at all (missing file,
        // unmounted share). Without this it shows up as a meaningless `'wht?' (2003334207)`.
        case 2003334207: return "'wht?' (2003334207, path could not be resolved)"
        default:
            let be = UInt32(bitPattern: status).bigEndian
            let bytes = withUnsafeBytes(of: be) { Array($0) }
            if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
                return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
            }
            return "OSStatus \(status)"
        }
    }
}

// MARK: - FLAC embedded picture

/// Neither AVFoundation nor AudioToolbox exposes FLAC `PICTURE` blocks, so for `.flac` the metadata block
/// headers are walked by hand: 4 bytes per block (type + length). Detection never reads image data;
/// `readPicture` reads exactly one block.
enum FlacArtwork {
    private static let pictureBlockType: UInt8 = 6
    /// Pictures bigger than this are not worth the memory (and are most likely not a cover).
    private static let maxPictureBlock: UInt64 = 64 << 20

    static func hasPicture(url: URL) throws -> Bool {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var found = false
        try walkBlocks(fh) { type, _, _ in
            if type == pictureBlockType { found = true; return false }
            return true
        }
        return found
    }

    /// The image of the best `PICTURE` block: front cover (picture type 3) if there is one, else the first.
    static func readPicture(url: URL) throws -> Data? {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var best: (offset: UInt64, length: UInt64)?
        var bestIsFront = false
        try walkBlocks(fh) { type, offset, length in
            guard type == pictureBlockType, length <= maxPictureBlock else { return true }
            try fh.seek(toOffset: offset)
            guard let t = try fh.read(upToCount: 4), t.count == 4 else { return true }
            let isFront = t.reduce(0, { $0 << 8 | UInt32($1) }) == 3
            if best == nil || (isFront && !bestIsFront) { best = (offset, length); bestIsFront = isFront }
            return !isFront                                                     // front cover: good enough
        }
        guard let best else { return nil }
        try fh.seek(toOffset: best.offset)
        guard let block = try fh.read(upToCount: Int(best.length)) else { return nil }
        return PictureBlock.imageData(from: block)
    }

    /// Calls `visit(type, dataOffset, dataLength)` for every metadata block until it returns false or the blocks end.
    fileprivate static func walkBlocks(_ fh: FileHandle, _ visit: (UInt8, UInt64, UInt64) throws -> Bool) throws {
        var offset: UInt64 = 0
        guard var head = try fh.read(upToCount: 10), head.count >= 4 else { return }
        if head.starts(with: [0x49, 0x44, 0x33]), head.count == 10 {          // leading ID3v2 tag: skip it
            let size = head[6...9].reduce(0) { $0 << 7 | UInt64($1 & 0x7F) }
            offset = 10 + size + (head[5] & 0x10 != 0 ? 10 : 0)                 // + footer
            try fh.seek(toOffset: offset)
            guard let h = try fh.read(upToCount: 4), h.count == 4 else { return }
            head = h
        }
        guard head.starts(with: [0x66, 0x4C, 0x61, 0x43]) else { return }      // "fLaC"
        if offset == 0 { offset = 4 } else { offset += 4 }

        for _ in 0..<128 {                                                      // sanity bound
            try fh.seek(toOffset: offset)
            guard let h = try fh.read(upToCount: 4), h.count == 4 else { return }
            let isLast = h[h.startIndex] & 0x80 != 0
            let type = h[h.startIndex] & 0x7F
            let length = UInt64(h[h.startIndex + 1]) << 16 | UInt64(h[h.startIndex + 2]) << 8 | UInt64(h[h.startIndex + 3])
            if type == 127 { return }
            if try !visit(type, offset + 4, length) { return }
            if isLast { return }
            offset += 4 + length
        }
    }
}

/// The Vorbis comment block of a FLAC file. AudioToolbox doesn't list its lyrics (AVFoundation does, but is much
/// slower), so they are read by hand, from the one block that holds them.
enum FlacComments {
    private static let vorbisCommentType: UInt8 = 4
    /// Comment blocks bigger than this are not worth the memory.
    private static let maxBlock: UInt64 = 16 << 20

    static func lyrics(url: URL) throws -> String? {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var lyrics: String?
        try FlacArtwork.walkBlocks(fh) { type, offset, length in
            guard type == vorbisCommentType else { return true }
            if length <= maxBlock {
                try fh.seek(toOffset: offset)
                if let block = try fh.read(upToCount: Int(length)) { lyrics = Self.lyrics(inComments: block) }
            }
            return false                                                        // there is one such block
        }
        return lyrics
    }

    /// The `LYRICS` (or `UNSYNCEDLYRICS`) comment of a Vorbis comment block: vendor string, then a count and the
    /// `NAME=value` entries, each with its length (all lengths u32 little-endian).
    static func lyrics(inComments block: Data) -> String? {
        let b = [UInt8](block)
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
        }
        guard let vendorLength = u32(), i + vendorLength <= b.count else { return nil }
        i += vendorLength
        guard let count = u32() else { return nil }
        for _ in 0..<min(count, 4096) {
            guard let length = u32(), i + length <= b.count else { return nil }
            let entry = String(decoding: b[i..<(i + length)], as: UTF8.self)
            i += length
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = entry[..<equals].lowercased()
            if name == "lyrics" || name == "unsyncedlyrics" { return String(entry[entry.index(after: equals)...]) }
        }
        return nil
    }
}

/// The FLAC `METADATA_BLOCK_PICTURE` layout, shared by FLAC files and Vorbis comments:
/// type, mime, description, width, height, depth, colors, length, data (all integers big-endian u32).
enum PictureBlock {
    /// The raw image bytes of a picture block, or nil if `block` doesn't parse as one.
    static func imageData(from block: Data) -> Data? {
        let b = [UInt8](block)
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }
        guard let type = u32(), type <= 20,
              let mimeLength = u32(), mimeLength <= 256, i + mimeLength <= b.count else { return nil }
        i += mimeLength
        guard let descriptionLength = u32(), i + descriptionLength + 16 <= b.count else { return nil }
        i += descriptionLength + 16                                             // + width, height, depth, colors
        guard let length = u32(), length > 0, i + length <= b.count else { return nil }
        return Data(b[i..<(i + length)])
    }

    /// What an AVFoundation artwork item holds: usually the plain image, but Vorbis comments carry a
    /// (base64) picture block. Anything that doesn't look like a block is returned unchanged.
    static func normalize(_ data: Data) -> Data {
        if data.starts(with: [0, 0, 0]), let image = imageData(from: data) { return image }
        if data.starts(with: "AAA".utf8),
           let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
           let image = imageData(from: decoded) { return image }
        return data
    }
}

// MARK: - AVFoundation backend

/// `AVURLAsset` metadata. Async, exposes every native item (album artist, performer, ...), but heavier
/// than AudioFile and its `duration` is unreliable for some OGG files.
enum AVFoundationBackend {
    static func read(url: URL) async throws -> RawTags {
        let asset = AVURLAsset(url: url)
        var raw = RawTags()
        do {
            let formats = try await asset.load(.availableMetadataFormats)
            raw.hasArtwork = false
            for format in formats {
                let items = try await asset.loadMetadata(for: format)
                for item in items {
                    if isArtwork(item) { raw.hasArtwork = true; continue }
                    // ID3v2.2 items have no identifier, only a bare 3-char key ("TT2", "TP1", ...).
                    guard let id = item.identifier?.rawValue ?? (item.key as? String),
                          let field = TagKeyMap.table[TagKeyMap.parse(identifier: id).key] else { continue }
                    let prefix = TagKeyMap.parse(identifier: id).prefix

                    // MP4 'trkn' is 8 bytes of binary: 00 00 <track:u16> <total:u16> 00 00
                    if prefix == "itsk", field == .track,
                       let d = try? await item.load(.dataValue), d.count >= 4 {
                        let n = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
                        if n > 0 { raw.set(.track, String(n)) }
                    } else if let s = try? await item.load(.stringValue) {
                        raw.set(field, s)
                    } else if let n = try? await item.load(.numberValue) {
                        raw.set(field, n.stringValue)
                    }
                }
            }
            if let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0 {
                raw.duration = d.seconds
            }
        } catch {
            throw TagReadError.unreadable("AVFoundation: \(error.localizedDescription)")
        }
        return raw
    }

    /// The lyrics of the file (nil = none, or unreadable), for the files whose lyrics the other backends don't see.
    static func lyrics(url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items {
                guard let id = item.identifier?.rawValue ?? (item.key as? String),
                      TagKeyMap.table[TagKeyMap.parse(identifier: id).key] == .lyrics,
                      let text = try? await item.load(.stringValue) else { continue }
                var raw = RawTags()
                raw.set(.lyrics, text)
                if let lyrics = raw.fields[.lyrics] { return lyrics }
            }
        }
        return nil
    }

    /// Artwork-only check (used when the tag read didn't go through AVFoundation). Reads item *keys* only,
    /// never the image data.
    static func hasEmbeddedArtwork(url: URL) async -> Bool? {
        let asset = AVURLAsset(url: url)
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            if items.contains(where: isArtwork) { return true }
        }
        return false
    }

    /// The image bytes of the first artwork item of the file (nil = none, or unreadable). Not for FLAC, whose
    /// pictures AVFoundation can't see (see `FlacArtwork`). Reads the image data, so only call it for the one
    /// file that is going to supply an album's art.
    static func embeddedArtwork(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items where isArtwork(item) {
                if let data = try? await item.load(.dataValue), !data.isEmpty { return PictureBlock.normalize(data) }
            }
        }
        return nil
    }

    /// Native keys that carry a picture: ID3 `APIC` (v2.3/2.4) / `PIC` (v2.2), MP4 `covr`, Vorbis/FLAC pictures.
    private static let artworkKeys: Set<String> = ["apic", "pic", "covr", "metadata_block_picture", "coverart"]

    private static func isArtwork(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyArtwork { return true }
        guard let id = item.identifier?.rawValue ?? (item.key as? String) else { return false }
        return artworkKeys.contains(TagKeyMap.parse(identifier: id).key)
    }
}

