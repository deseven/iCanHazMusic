import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Raw tag bag

/// Tags as extracted from one or more backends, keyed by canonical field. First non-empty value wins.
struct RawTags: Sendable {
    var fields: [TagField: String] = [:]
    var duration: TimeInterval?

    mutating func set(_ field: TagField, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !v.isEmpty, fields[field] == nil else { return }
        fields[field] = v
    }

    /// Fills only what's still missing.
    mutating func merge(_ other: RawTags) {
        for (k, v) in other.fields where fields[k] == nil { fields[k] = v }
        if duration == nil { duration = other.duration }
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

// MARK: - AVFoundation backend

/// `AVURLAsset` metadata. Async, exposes every native item (album artist, performer, ...), but heavier
/// than AudioFile and its `duration` is unreliable for some OGG files.
enum AVFoundationBackend {
    static func read(url: URL) async throws -> RawTags {
        let asset = AVURLAsset(url: url)
        var raw = RawTags()
        do {
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let items = try await asset.loadMetadata(for: format)
                for item in items {
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
}

