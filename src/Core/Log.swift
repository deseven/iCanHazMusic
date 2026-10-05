// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Simple stdout logger for debug output.
/// All messages are prefixed with `[iCHM]` for easy identification.
enum Log {
    static func info(_ message: String) {
        print("[\(AppConstants.appShortName)] \(message)")
    }

    static func error(_ message: String) {
        print("[\(AppConstants.appShortName)] ERROR: \(message)")
    }
}
