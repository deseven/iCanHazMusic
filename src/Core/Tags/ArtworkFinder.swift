import Foundation

/// Where a track's album art would come from. Detection only - no image is ever read or decoded.
///
/// Priority (first hit wins, nothing further is looked at):
///  1. `.cover`    - `cover|folder|album|front` + `jpg|jpeg|png` (case-insensitive) next to the file
///  2. `.embedded` - artwork inside the audio file's own tags
///  3. `.anyImage` - any other `jpg|jpeg|png` in the file's folder (absolute last resort)
enum ArtworkSource: Sendable, Equatable {
    case cover(String)
    case embedded
    case anyImage(String)
    case none

    /// Short text for tables: the image's file name, or "embedded".
    var label: String {
        switch self {
        case .cover(let n), .anyImage(let n): n
        case .embedded: "embedded"
        case .none: ""
        }
    }
}

/// Folder-level artwork lookup (priority 1 and 3).
enum ExternalArtwork {
    static let extensions = ["jpg", "jpeg", "png"]
    static let preferredNames = ["cover", "folder", "album", "front"]

    /// Result of looking at one directory. Names are as stored on disk (original case).
    struct Listing: Sendable {
        /// Best `cover|folder|album|front` image: cover > folder > album > front, then jpg > jpeg > png.
        var preferred: String?
        /// First image of any name (natural order) other than `preferred`, the last resort when the preferred
        /// one (or the embedded art) turns out to be unusable.
        var anyImage: String?

        static let empty = Listing()
    }

    /// Blocking: lists the directory once and classifies its files. Hidden files (incl. AppleDouble
    /// `._cover.jpg` companions on network shares) are ignored.
    static func scan(directory: URL) -> Listing {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return .empty }

        var best: (rank: Int, name: String)?
        var images: [String] = []
        for name in names where !name.hasPrefix(".") {
            let ext = (name as NSString).pathExtension.lowercased()
            guard let extIndex = extensions.firstIndex(of: ext) else { continue }
            images.append(name)
            let base = ((name as NSString).deletingPathExtension).lowercased()
            if let nameIndex = preferredNames.firstIndex(of: base) {
                let rank = nameIndex * extensions.count + extIndex
                if best == nil || rank < best!.rank { best = (rank, name) }
            }
        }
        let first = images.filter { $0 != best?.name }.min { $0.localizedStandardCompare($1) == .orderedAscending }
        return Listing(preferred: best?.name, anyImage: first)
    }
}

/// Caches `ExternalArtwork.Listing` per directory so an album with N tracks lists its folder once
/// (matters on a NAS). Concurrent requests for the same folder share one in-flight lookup.
final class ArtworkDirectoryCache: @unchecked Sendable {
    private var tasks: [String: Task<ExternalArtwork.Listing, Never>] = [:]
    private let lock = NSLock()
    private let timeout: TimeInterval

    init(timeout: TimeInterval) { self.timeout = timeout }

    func listing(for directory: URL) async -> ExternalArtwork.Listing {
        await task(for: directory).value
    }

    private func task(for directory: URL) -> Task<ExternalArtwork.Listing, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = tasks[directory.path] { return existing }
        let timeout = self.timeout
        let task = Task {
            // A stalled mount is treated as "no folder images" rather than hanging the read.
            (try? await TagReader.offload(timeout: timeout) { ExternalArtwork.scan(directory: directory) }) ?? .empty
        }
        tasks[directory.path] = task
        return task
    }
}
