// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One thing to read the tags of.
enum ReadInput: Sendable {
    /// An audio file (that may not exist: it is then reported as failed).
    case file(URL)
    /// A track of a CUE sheet that is imported. The audio file is read, and what the track becomes depends on whether
    /// the sheet cuts the file (`CueTrack.cutsFile`): a part of the file with the sheet's tags first, or the plain file
    /// with its own tags first (`CueTrack.importResult`).
    case cueTrack(CueTrack)
    /// A track that is in the playlist as a part of a file (reloading it): it stays one, whatever the sheet says now
    /// (`CueTrack.tagResult`).
    case cuePart(CueTrack)
    /// Something that can't be read, such as a track that is not in its sheet (any more); it fails right away.
    case unavailable(URL, reason: String)

    /// The audio file whose tags have to be read for this input, if any.
    var audioURL: URL? {
        switch self {
        case .file(let url): url
        case .cueTrack(let track), .cuePart(let track): track.audio
        case .unavailable: nil
        }
    }

    /// The URL the result will have: the file, or the pseudo path of a part of a file.
    var resultURL: URL {
        switch self {
        case .file(let url): url
        case .cueTrack(let track): track.cutsFile ? track.url : track.audio
        case .cuePart(let track): track.url
        case .unavailable(let url, _): url
        }
    }
}

/// Turns whatever the user handed us (files, directories, a mix) into the ordered list of audio files to read.
enum AudioFileGatherer {
    /// Extensions macOS 15.4+ can open natively (compared case-insensitively).
    /// - WMA/APE/WavPack/MPC etc. are absent: neither AudioToolbox nor AVFoundation opens them.
    /// - "opus" and "oga": Ogg Opus (mono/stereo; multichannel Opus doesn't open) and Ogg Vorbis. Ogg FLAC in an
    ///   ".oga" opens without any audio, so its tracks fail to play ("the file has no audio").
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "ogg", "opus", "oga",
        "wav", "wave", "aif", "aiff", "aifc", "caf",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Blocking, call it off the main thread. Checks `Task.isCancelled` and returns what it has found so far
    /// when cancelled.
    ///
    /// - Directories are walked recursively (hidden files and package contents are skipped).
    /// - Only supported file types are kept, whether they were passed explicitly or found in a directory.
    /// - Duplicates (the same file passed twice, or inside a directory that was passed too) are dropped.
    /// - The result is sorted alphabetically (Finder-like natural order) one path component at a time, so
    ///   files of one directory stay together and directories are visited in alphabetical order.
    static func gather(from inputs: [URL]) -> [URL] {
        walk(inputs) { isSupported($0) }
    }

    /// Like `gather`, but with CUE sheets: they are read first, every track of a sheet takes the place of the sheet in
    /// the order, and the audio files a sheet names (its `FILE` lines) are left out, whatever else was found: they
    /// come in through the sheet's tracks (which become the plain files, or parts of them, once the files are read: see
    /// `CueTrack.importResult`). A sheet that can't be read, or only names unsupported files, adds nothing (the
    /// files it names are still the sheet's).
    static func gatherInputs(from inputs: [URL]) -> [ReadInput] {
        let found = walk(inputs) { isSupported($0) || CueSheet.isCueFile($0) }

        var sheets: [String: CueSheet.Contents] = [:]
        var references = References()
        for url in found where CueSheet.isCueFile(url) {
            if Task.isCancelled { break }
            guard let contents = CueSheet.contents(of: url) else {
                Log.error("can't read cue sheet \(url.path)")
                continue
            }
            if contents.tracks.isEmpty {
                Log.error("cue sheet \(url.lastPathComponent): no playable tracks (\(contents.skipped) skipped)")
            } else if contents.skipped > 0 {
                Log.info("cue sheet \(url.lastPathComponent): \(contents.skipped) track(s) skipped")
            }
            sheets[url.path] = contents
            references.add(contents.referenced)
        }

        var out: [ReadInput] = []
        for url in found {
            if CueSheet.isCueFile(url) {
                out += (sheets[url.path]?.tracks ?? []).map(ReadInput.cueTrack)
            } else if !references.contains(url) {
                out.append(.file(url))
            }
        }
        return out
    }

    /// The files named by sheets. On a file system that ignores case a sheet may name `ALBUM.FLAC` for `album.flac`: that
    /// is the same file, so it is recognised (by asking the file system, never by guessing).
    private struct References {
        private var exact = Set<String>()
        private var byLowercasedPath: [String: [URL]] = [:]

        mutating func add(_ urls: [URL]) {
            for url in urls {
                exact.insert(url.path)
                byLowercasedPath[url.path.lowercased(), default: []].append(url)
            }
        }

        func contains(_ url: URL) -> Bool {
            if exact.contains(url.path) { return true }
            guard let candidates = byLowercasedPath[url.path.lowercased()] else { return false }
            return candidates.contains { Self.isSameFile($0, url) }
        }

        private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
            let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
            guard let x = try? a.resourceValues(forKeys: key).fileResourceIdentifier as? NSObject,
                  let y = try? b.resourceValues(forKeys: key).fileResourceIdentifier as? NSObject else { return false }
            return x.isEqual(y)
        }
    }

    private static func walk(_ inputs: [URL], accepting accepts: (URL) -> Bool) -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        var found: [(url: URL, components: [String])] = []

        func add(_ url: URL) {
            let url = url.standardizedFileURL
            if seen.insert(url.path).inserted { found.append((url, url.pathComponents)) }
        }

        for input in inputs {
            if Task.isCancelled { break }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: input.path, isDirectory: &isDir) else { continue }

            if !isDir.boolValue {
                if accepts(input) { add(input) }
                continue
            }
            guard let enumerator = fm.enumerator(
                at: input,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if Task.isCancelled { break }
                guard accepts(url) else { continue }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                add(url)
            }
        }

        found.sort { precedes($0.components, $1.components) }
        return found.map(\.url)
    }

    private static func precedes(_ a: [String], _ b: [String]) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            switch x.localizedStandardCompare(y) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        return a.count < b.count
    }
}
