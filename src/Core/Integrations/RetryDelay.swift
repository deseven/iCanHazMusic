// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// How long a background queue (scrobbling, LRCLIB) waits before it tries a call again that failed for a temporary reason.
enum RetryDelay {
    /// What a server asks for (`Retry-After`) is waited for, but not longer than this: a queue is blocked while it
    /// waits, and what is behind the call (or the call itself, a now playing update) may well be stale by then.
    static let maxRetryAfter: TimeInterval = 120

    /// What the server asked for if it did (at most `maxRetryAfter`), otherwise our own exponential backoff: 1 s after
    /// the first try, then twice as long each time.
    static func delay(afterAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> Duration {
        if let retryAfter, retryAfter > 0 {
            return .seconds(Int(min(retryAfter, maxRetryAfter).rounded(.up)))
        }
        return .seconds(1 << min(max(attempt - 1, 0), 30))
    }
}
