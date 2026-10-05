// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The playlist file formats the app can write (Export) and read (Import).
enum PlaylistFormat: String, CaseIterable {
    case m3u8, m3u, pls

    var fileExtension: String { rawValue }

    init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }
}

/// Reading and writing playlist files of other players. Foundation only.
///
/// - Export writes absolute paths, UTF-8 for all three formats (also `.m3u`, which has no defined encoding).
/// - Import only takes the *file paths* out of a playlist, in playlist order. Titles, artists and durations
///   in the file (`#EXTINF`, PLS `Title`/`Length`) are ignored: the tags are read from the files themselves,
///   like for any other import.
enum PlaylistExchange {
    // MARK: - Detection

    /// A regular file with a playlist extension (a directory that happens to be called `x.m3u` is not one).
    static func isPlaylistFile(_ url: URL) -> Bool {
        guard url.isFileURL, PlaylistFormat(fileExtension: url.pathExtension) != nil else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    // MARK: - Export

    static func data(for entries: [TrackEntry], format: PlaylistFormat) -> Data {
        let text: String
        switch format {
        case .m3u, .m3u8: text = m3u(entries)
        case .pls: text = pls(entries)
        }
        return Data(text.utf8)
    }

    private static func m3u(_ entries: [TrackEntry]) -> String {
        var lines = ["#EXTM3U"]
        for entry in entries {
            let seconds = entry.duration.map { Int($0.rounded()) } ?? -1
            lines.append("#EXTINF:\(seconds),\(label(entry))")
            lines.append(singleLine(entry.path))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func pls(_ entries: [TrackEntry]) -> String {
        var lines = ["[playlist]"]
        for (i, entry) in entries.enumerated() {
            let n = i + 1
            lines.append("File\(n)=\(singleLine(entry.path))")
            lines.append("Title\(n)=\(label(entry))")
            lines.append("Length\(n)=\(entry.duration.map { Int($0.rounded()) } ?? -1)")
        }
        lines.append("NumberOfEntries=\(entries.count)")
        lines.append("Version=2")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func label(_ entry: TrackEntry) -> String {
        singleLine("\(entry.artist) - \(entry.title)")
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    // MARK: - Import

    /// Blocking, call it off the main thread. The audio files the playlists point to, in playlist order (the
    /// playlists in the order given), without duplicates. Entries that aren't local files or have no supported
    /// audio extension are dropped; files that don't exist are *kept*, so the tag reader reports them as failed.
    static func audioFiles(in playlists: [URL]) -> [URL] {
        var seen = Set<String>()
        var files: [URL] = []
        for playlist in playlists {
            if Task.isCancelled { break }
            guard let data = try? Data(contentsOf: playlist) else {
                Log.error("can't read playlist \(playlist.path)")
                continue
            }
            let format = PlaylistFormat(fileExtension: playlist.pathExtension) ?? .m3u
            let base = playlist.deletingLastPathComponent()
            for url in parse(decode(data), format: format, baseDirectory: base) where AudioFileGatherer.isSupported(url) {
                if seen.insert(url.path).inserted { files.append(url) }
            }
        }
        return files
    }

    /// The local file URLs listed in a playlist, in order. Relative paths are resolved against `baseDirectory`
    /// (the playlist's own directory).
    static func parse(_ text: String, format: PlaylistFormat, baseDirectory: URL) -> [URL] {
        let lines = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).components(separatedBy: .newlines)
        let paths: [String]
        switch format {
        case .m3u, .m3u8:
            paths = lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        case .pls:
            var numbered: [(number: Int, path: String)] = []
            for line in lines {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                guard key.hasPrefix("file"), let number = Int(key.dropFirst(4)) else { continue }
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { numbered.append((number, value)) }
            }
            paths = numbered.sorted { $0.number < $1.number }.map(\.path)
        }
        return paths.compactMap { resolve($0, relativeTo: baseDirectory) }
    }

    /// UTF-8, else Latin-1, which accepts any bytes (older `.m3u` files use the system
    /// encoding).
    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func resolve(_ entry: String, relativeTo base: URL) -> URL? {
        if entry.lowercased().hasPrefix("file://") {
            guard let url = URL(string: entry), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        if entry.contains("://") { return nil }   // http streams and the like
        if entry.hasPrefix("~") {
            return URL(fileURLWithPath: (entry as NSString).expandingTildeInPath, isDirectory: false).standardizedFileURL
        }
        if entry.hasPrefix("/") {
            return URL(fileURLWithPath: entry, isDirectory: false).standardizedFileURL
        }
        return base.appendingPathComponent(entry, isDirectory: false).standardizedFileURL
    }
}
