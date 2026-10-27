// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

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

private let hexDigits = Array("0123456789abcdef".utf8)

extension Sequence<UInt8> {
    /// Lower-case hex, two digits per byte (digests used as keys and signatures). The same text as
    /// `String(format: "%02x")` per byte, without its cost (keys are made while the playlist renders rows).
    var hexString: String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
