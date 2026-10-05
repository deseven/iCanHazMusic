// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// One line of synchronised lyrics.
struct LyricLine: Equatable, Sendable {
    /// Seconds into the track at which the line starts.
    let time: TimeInterval
    /// Can be empty: a pause between the verses.
    let text: String
}

/// The lyrics of one track, and where they come from.
///
/// They are plain text or synchronised (LRCLIB has those, and so have files whose lyrics tag holds an LRC text):
/// then `lrc` is the original text and `lines` its lines in time order; `plain` is always there, without
/// timestamps.
struct Lyrics: Equatable, Sendable {
    enum Source: String, Sendable {
        /// In the tags of the file: the source of truth.
        case embedded
        case lrclib
    }

    /// Lyrics longer than this (in UTF-8 bytes) are not lyrics, they are something else in the wrong tag.
    static let maxBytes = 1 << 20

    let source: Source
    let plain: String
    /// The synchronised text in LRC format, nil if there is none.
    let lrc: String?
    /// The lines of `lrc`, empty if there is none.
    let lines: [LyricLine]

    var isSynced: Bool { !lines.isEmpty }

    /// `plain` and `lrc` are what the source gave; at least one of them has to hold something. An `lrc` without
    /// a single timed line doesn't count, and a missing `plain` is made from the lines.
    init?(source: Source, plain: String?, lrc: String?) {
        let lines = lrc.map(LRC.parse) ?? []
        let plain = plain.flatMap(Self.normalized) ?? lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, plain.utf8.count <= Self.maxBytes else { return nil }
        self.source = source
        self.plain = plain
        self.lines = lines
        self.lrc = lines.isEmpty ? nil : lrc
    }

    /// What a file's lyrics tag holds: mostly plain text, sometimes an LRC text.
    static func embedded(_ text: String) -> Lyrics? {
        guard let text = normalized(text) else { return nil }
        let timed = LRC.parse(text)
        if timed.count >= 2 { return Lyrics(source: .embedded, plain: nil, lrc: text) }
        return Lyrics(source: .embedded, plain: text, lrc: nil)
    }

    /// Line breaks as `\n`, no blank space around; nil for nothing, or too much.
    static func normalized(_ text: String) -> String? {
        let clean = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= maxBytes else { return nil }
        return clean
    }

    /// The index of the line that is being sung at `time`: the last one that has started. nil before the first.
    func lineIndex(at time: TimeInterval) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {                                                      // first line that starts after `time`
            let mid = (low + high) / 2
            if lines[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}

/// How lyrics are told apart: a hash of artist, title and album. The comparison ignores case and the blank space
/// around the values, so the same track read from two files (or typed in another case) is one entry.
enum LyricsKey {
    static func make(artist: String, title: String, album: String) -> String {
        // Unit separator: can't be in a tag for real, so ("a b", "c") and ("a", "b c") differ.
        let text = [artist, title, album].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The LRC format: `[mm:ss.xx]text` lines, possibly several timestamps in front of one text, with metadata lines
/// (`[ar:Artist]`, `[ti:Title]`, ...) in between and an optional `[offset:ms]`.
enum LRC {
    /// The timed lines, in time order. Everything that isn't a timed line is dropped.
    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0

        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                } else if times.isEmpty {
                    rest = ""                                                   // a metadata line
                    break
                } else {
                    break
                }
            }
            guard !times.isEmpty else { continue }
            let content = String(rest).replacingOccurrences(of: #"<\d+:\d{1,2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for time in times { lines.append(LyricLine(time: time, text: content)) }
        }

        if offset != 0 {
            lines = lines.map { LyricLine(time: max($0.time - offset, 0), text: $0.text) }
        }
        return lines.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// `mm:ss`, `mm:ss.xx` or `mm:ss.xxx`; the digits after the point are a decimal fraction.
    private static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = digits(parts[0]) else { return nil }
        var seconds: Substring = parts[1]
        var fraction: Substring = parts.count == 3 ? parts[2] : ""
        if parts.count == 2, let point = seconds.firstIndex(where: { $0 == "." || $0 == "," }) {
            fraction = seconds[seconds.index(after: point)...]
            seconds = seconds[..<point]
        }
        guard let whole = digits(seconds) else { return nil }
        var time = Double(minutes) * 60 + Double(whole)
        if !fraction.isEmpty {
            guard digits(fraction) != nil, let value = Double("0." + fraction) else { return nil }
            time += value
        }
        return time
    }

    private static func digits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else { return nil }
        return Int(text)
    }
}
