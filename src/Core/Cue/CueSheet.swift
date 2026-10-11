// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A parsed `.cue` sheet: what it says, not yet checked against the file system. Foundation only.
///
/// Understood: `FILE`, `TRACK` (audio or not), `TITLE`, `PERFORMER`, `INDEX` and `REM DATE`; everything else
/// (`CATALOG`, `ISRC`, `FLAGS`, `PREGAP`, `SONGWRITER`, other `REM`s, ...) is ignored. Commands are case-insensitive,
/// values may be quoted or not. `TITLE`/`PERFORMER` before the first `TRACK` describe the album.
///
/// The parser takes the sheet as it is written: nothing is guessed (no other file names, no other encodings than
/// the ones in `decode`).
struct CueSheet: Equatable, Sendable {
    /// One `TRACK` of the sheet.
    struct Entry: Equatable, Sendable {
        var number: Int
        /// `TRACK 02 AUDIO`; anything else (`MODE1/2352`, ...) is data and never played. A missing type counts as audio.
        var isAudio = true
        var title: String?
        var performer: String?
        var year: String?
        /// Index into `CueSheet.files` of the `FILE` the track belongs to; `nil` if there was none before it.
        var file: Int?
        /// `INDEX nn` -> seconds from the start of the file.
        var indices: [Int: TimeInterval] = [:]

        /// Where the track starts: `INDEX 01` (the pregap, `INDEX 00`, belongs to the previous track); a track that
        /// has no `INDEX 01` starts at the lowest index it has. `nil` if it has no index at all.
        var start: TimeInterval? {
            if let time = indices[1] { return time }
            return indices.min { $0.key < $1.key }?.value
        }
    }

    var title: String?
    var performer: String?
    var year: String?
    /// The names given by the `FILE` commands, in order, as written.
    var files: [String] = []
    var entries: [Entry] = []

    /// CD frames per second (`MM:SS:FF`).
    static let framesPerSecond = 75.0
    /// A sheet is a few kilobytes; this is only a guard against something else named `.cue`.
    static let maxSize = 4 << 20

    static func isCueFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "cue"
    }

    // MARK: - Reading

    /// Blocking. `nil` if the file can't be read or is too big to be a sheet.
    static func load(_ url: URL) -> CueSheet? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maxSize else { return nil }
        return parse(decode(data))
    }

    /// UTF-8 (with or without a BOM) or UTF-16 with a BOM; anything else is read as Windows-1252 (which is what the
    /// sheets of Windows rippers are), and as Latin-1 where that has holes.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func parse(_ text: String) -> CueSheet {
        var sheet = CueSheet()
        var current: Entry?
        var currentFile: Int?

        func finish() {
            if let entry = current { sheet.entries.append(entry) }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\u{FEFF}")))
            guard !line.isEmpty else { continue }
            let (command, rest) = split(line)

            switch command.uppercased() {
            case "FILE":
                finish()
                guard let name = fileName(rest) else { currentFile = nil; continue }
                sheet.files.append(name)
                currentFile = sheet.files.count - 1
            case "TRACK":
                finish()
                let words = rest.split(whereSeparator: \.isWhitespace)
                guard let first = words.first, let number = Int(first) else { continue }
                current = Entry(number: number, isAudio: words.count < 2 || words[1].uppercased() == "AUDIO",
                                file: currentFile)
            case "TITLE":
                let value = unquote(rest)
                if current != nil { current?.title = value.isEmpty ? nil : value } else { sheet.title = value.isEmpty ? nil : value }
            case "PERFORMER":
                let value = unquote(rest)
                if current != nil { current?.performer = value.isEmpty ? nil : value } else { sheet.performer = value.isEmpty ? nil : value }
            case "INDEX":
                let words = rest.split(whereSeparator: \.isWhitespace)
                guard current != nil, words.count >= 2, let number = Int(words[0]), let time = time(String(words[1])) else { continue }
                current?.indices[number] = time
            case "REM":
                let (key, value) = split(rest)
                guard key.uppercased() == "DATE" else { continue }
                let year = unquote(value)
                if year.isEmpty { continue }
                if current != nil { current?.year = year } else { sheet.year = year }
            default:
                break
            }
        }
        finish()
        return sheet
    }

    /// `MM:SS:FF` (75 frames to the second, minutes may have more than two digits) in seconds.
    static func time(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let minutes = Int(parts[0]), let seconds = Int(parts[1]), let frames = Int(parts[2]),
              minutes >= 0, seconds >= 0, frames >= 0 else { return nil }
        return Double(minutes * 60 + seconds) + Double(frames) / framesPerSecond
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(where: \.isWhitespace) else { return (line, "") }
        return (String(line[..<space]), line[space...].trimmingCharacters(in: .whitespaces))
    }

    /// The value without the quotes around it (the closing one may be missing).
    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            value.removeFirst()
            if value.hasSuffix("\"") { value.removeLast() }
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// `"my file.flac" WAVE`, or `file.flac WAVE`, or just `file.flac`.
    private static func fileName(_ text: String) -> String? {
        let name: String
        if text.hasPrefix("\""), let close = text.lastIndex(of: "\""), close > text.startIndex {
            name = String(text[text.index(after: text.startIndex)..<close])
        } else {
            var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count >= 2 { words.removeLast() }   // the type (WAVE, MP3, ...)
            name = words.joined(separator: " ")
        }
        return name.isEmpty ? nil : name
    }

    // MARK: - Against the file system

    /// What a sheet makes of the files next to it.
    struct Contents: Equatable, Sendable {
        let sheet: URL
        /// The playable tracks, in sheet order.
        let tracks: [CueTrack]
        /// The audio files the sheet names (whether it can use them or not): these are the sheet's, and are not
        /// added on their own.
        let referenced: [URL]
        /// Tracks of the sheet that were left out: data tracks, files of an unsupported format, tracks without an
        /// index or without any length.
        let skipped: Int
    }

    /// The tracks of the sheet at `sheet`; `nil` if it can't be read.
    static func contents(of sheet: URL) -> Contents? {
        load(sheet)?.resolve(sheet: sheet)
    }

    /// Resolves the file names against the directory of the sheet (an absolute one stays as it is; nothing else is
    /// tried) and works out where every track starts and ends: a track runs to the start of the next one in the same
    /// file (so a pregap goes to the end of the track before it), the last one of a file to the end of the file.
    func resolve(sheet: URL) -> Contents {
        let directory = sheet.deletingLastPathComponent()
        let urls = files.map { name -> URL in
            let url = name.hasPrefix("/")
                ? URL(fileURLWithPath: name, isDirectory: false)
                : directory.appendingPathComponent(name, isDirectory: false)
            return url.standardizedFileURL
        }

        // The number in a track's path: its TRACK number, unless the sheet repeats one (every FILE of a multi-disc sheet
        // may start again at 01), then the place in the sheet.
        let numbers = entries.map(\.number)
        let ordinals = Set(numbers).count != numbers.count

        var tracks: [CueTrack] = []
        var skipped = 0
        for (index, entry) in entries.enumerated() {
            guard entry.isAudio, let file = entry.file, let start = entry.start,
                  AudioFileGatherer.isSupported(urls[file]) else {
                skipped += 1
                continue
            }
            var end: TimeInterval?
            for next in entries[(index + 1)...] {
                guard next.file == file else { break }
                if let time = next.start { end = time; break }
            }
            if let end, end <= start {
                skipped += 1
                continue
            }
            tracks.append(CueTrack(
                sheet: sheet, pathNumber: ordinals ? index + 1 : entry.number, trackNumber: entry.number,
                audio: urls[file], start: start, end: end,
                title: entry.title, artist: entry.performer, albumArtist: performer,
                album: title, year: entry.year ?? year
            ))
        }

        // How many tracks each file has (the ones that are left, not the skipped ones): more than one = the file is cut.
        var perFile: [String: Int] = [:]
        for track in tracks { perFile[track.audio.path, default: 0] += 1 }
        for index in tracks.indices { tracks[index].fileTrackCount = perFile[tracks[index].audio.path] ?? 1 }

        var seen = Set<String>()
        let referenced = urls.filter { seen.insert($0.path).inserted }
        return Contents(sheet: sheet, tracks: tracks, referenced: referenced, skipped: skipped)
    }
}
