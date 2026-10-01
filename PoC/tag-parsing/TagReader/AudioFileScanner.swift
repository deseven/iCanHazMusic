import Foundation

/// Expands folders into lists of audio files.
public enum AudioFileScanner {
    /// Extensions that macOS 15.4+ can open natively.
    /// - WMA/APE/WavPack/MPC etc. are absent: neither AudioToolbox nor AVFoundation opens them.
    /// - "oga" and "opus" are deliberately excluded (project decision). Tags in them are readable, but
    ///   AVAudioPlayer.prepareToPlay() fails for Opus on 26.x. Add them here to enable.
    public static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "ogg",
        "wav", "wave", "aif", "aiff", "aifc", "caf",
    ]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Files passed explicitly are kept as-is (so unsupported ones surface as "failed" rows);
    /// folders are walked recursively and filtered by extension. Hidden files are skipped.
    /// Result is de-duplicated and sorted in natural path order. Blocking - call off the main thread.
    public static func scan(urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(at: url,
                                            includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var found: [URL] = []
                for case let f as URL in e where isSupported(f) {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        found.append(f)
                    }
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                for f in found where seen.insert(f.path).inserted { out.append(f) }
            } else if seen.insert(url.path).inserted {
                out.append(url)
            }
        }
        return out
    }
}
