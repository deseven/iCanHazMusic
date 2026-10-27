// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// WavPack and APE files (`ExtraFormat`), which neither AudioToolbox nor AVFoundation can open: they are asked about
/// nothing, they would only fail or waste time.
///
/// - The length and the format label come from the file's own decoder (`PCMSource`): its header is exact and cheap to
///   open, and a file the decoder refuses is a file that can't be played, so it is reported as unreadable here already.
/// - The tags come from the APEv2 tag at the end of the file (`ApeTag`), keys case-insensitive through `TagKeyMap`,
///   lyrics included (no pass of their own, unlike other formats). A WavPack file may have an ID3v1 tag instead, or as
///   well: it fills in what the APEv2 tag lacks.
/// - The cover is the binary item `Cover Art (Front)` (else any `Cover Art (...)`) of the APEv2 tag: a file name, a NUL,
///   then the image. Detection only looks at the item, `embeddedArtwork` reads the image.
enum ApeTagBackend {
    static func handles(_ url: URL) -> Bool {
        ExtraFormat(url: url) != nil
    }

    /// Blocking.
    static func read(url: URL) throws -> RawTags {
        var raw = RawTags()
        do {   // the decoder is done with the file before the tags are read
            let source = try PCMSources.open(url: url)
            let rate = source.processingFormat.sampleRate
            if source.length > 0, rate > 0 { raw.duration = Double(source.length) / rate }
            raw.codec = source.codec
        }

        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let (tag, id3v1) = try ApeTag.read(fh)
        for (field, value) in tag?.fields ?? [:] { raw.set(field, value) }
        for (field, value) in id3v1 ?? [:] { raw.set(field, value) }
        raw.hasArtwork = tag?.cover != nil
        return raw
    }

    /// The image of the cover, `nil` if the file has none. Blocking, reads the whole image.
    static func embeddedArtwork(url: URL) throws -> Data? {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        guard let tag = try ApeTag.read(fh).tag, let cover = tag.cover,
              let value = try tag.value(of: cover, from: fh) else { return nil }
        return ApeTag.image(inCover: value)
    }
}
