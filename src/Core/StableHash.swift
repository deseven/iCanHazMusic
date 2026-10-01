import Foundation

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
