import Foundation

/// Temporary stand-in until playlists can actually be populated: generates a deterministic
/// fake playlist (5-10 albums with 10-15 tracks each) seeded by the playlist name, so the
/// same playlist always shows the same content.
enum MockPlaylist {
    private static let adjectives = ["Silent", "Electric", "Broken", "Golden", "Midnight", "Crimson", "Hollow", "Distant", "Neon", "Paper", "Velvet", "Burning", "Frozen", "Lost", "Wild", "Slow"]
    private static let nouns = ["Echoes", "Machines", "Gardens", "Rivers", "Dreams", "Signals", "Shadows", "Highways", "Oceans", "Mirrors", "Engines", "Horizons", "Letters", "Towers", "Storms", "Satellites"]
    private static let names = ["The", "Aurora", "Kite", "Monolith", "Lumen", "Cassette", "Orbit", "Delta", "Harbor", "Nova", "Pilot", "Quartz", "Radio", "Sable", "Tundra", "Vega"]
    private static let codecs = ["CBR 320", "VBR V0", "CBR 192", "FLAC 16/44.1", "FLAC 24/96", "AAC 256", "ALAC 16/44.1", "OGG Q6"]

    static func make(for playlistName: String) -> Playlist {
        var rng = SplitMix64(state: playlistName.stableHash)
        let albumCount = Int.random(in: 5...10, using: &rng)
        var albums: [Album] = []
        albums.reserveCapacity(albumCount)

        for _ in 0..<albumCount {
            let artist = "\(names.randomElement(using: &rng)!) \(nouns.randomElement(using: &rng)!)"
            let title = "\(adjectives.randomElement(using: &rng)!) \(nouns.randomElement(using: &rng)!)"
            let year = Int.random(in: 1965...2025, using: &rng)
            let codec = codecs.randomElement(using: &rng)!
            let trackCount = Int.random(in: 10...15, using: &rng)
            var tracks: [Track] = []
            tracks.reserveCapacity(trackCount)
            for t in 0..<trackCount {
                tracks.append(Track(
                    number: t + 1,
                    title: "\(adjectives.randomElement(using: &rng)!) \(nouns.randomElement(using: &rng)!)",
                    duration: TimeInterval(Int.random(in: 90...480, using: &rng)),
                    codec: codec
                ))
            }
            albums.append(Album(artist: artist, title: title, year: year, tracks: tracks))
        }
        return Playlist(albums: albums)
    }
}

/// Small, fast, seedable generator (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension String {
    /// FNV-1a over the UTF-8 bytes. Unlike `hashValue` it is stable across launches.
    var stableHash: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
