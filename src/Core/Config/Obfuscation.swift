// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Keeps secrets (the passwords and tokens of the scrobbling services) in `config.json` from being readable at a
/// glance: in a backup, in a screenshot of the file, in a synced dotfiles repository.
///
/// The text is XOR-ed with `key` (repeated) and written as base64. The key is in the sources and in the binary, so
/// this is no protection against anyone who looks for it, and nobody should rely on it for more than that.
enum Obfuscation {
    /// Changing it makes every secret saved so far unreadable (they are then treated as empty).
    static let key = "22d7ece7b0c98fd1de7a120d6e218169"

    /// `text` XOR-ed with `key`, as base64. An empty text stays empty.
    static func obfuscated(_ text: String) -> String {
        Data(xor(Array(text.utf8))).base64EncodedString()
    }

    /// The reverse of `obfuscated`; nil for anything that isn't base64 of UTF-8 text. An empty string stays empty.
    static func deobfuscated(_ encoded: String) -> String? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: Data(xor(Array(data))), encoding: .utf8)
    }

    private static func xor(_ bytes: [UInt8]) -> [UInt8] {
        let key = Array(key.utf8)
        return bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] }
    }
}
