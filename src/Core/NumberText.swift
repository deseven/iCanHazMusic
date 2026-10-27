// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

extension Int {
    /// At least two digits, the same text as `String(format: "%02d")` without its cost (playlist rows are made
    /// while scrolling).
    var twoDigits: String {
        (0..<10).contains(self) ? "0\(self)" : "\(self)"
    }
}
