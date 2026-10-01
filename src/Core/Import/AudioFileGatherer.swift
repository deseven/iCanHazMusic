import Foundation

/// Turns whatever the user handed us (files, directories, a mix) into the ordered list of audio files to read.
enum AudioFileGatherer {
    /// Extensions macOS 15.4+ can open natively (compared case-insensitively).
    /// - WMA/APE/WavPack/MPC etc. are absent: neither AudioToolbox nor AVFoundation opens them.
    /// - "oga" and "opus" are deliberately excluded (project decision): AVAudioPlayer fails to play Opus.
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "ogg",
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
                if isSupported(input) { add(input) }
                continue
            }
            guard let enumerator = fm.enumerator(
                at: input,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if Task.isCancelled { break }
                guard isSupported(url) else { continue }
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
