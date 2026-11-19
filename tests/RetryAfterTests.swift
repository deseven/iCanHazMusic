// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Retry-After")
    struct RetryAfterTests {
        private let now = Date(timeIntervalSince1970: 1_700_000_000)    // Tue, 14 Nov 2023 22:13:20 GMT

        @Test("Retry-After is seconds or an HTTP date; nonsense is ignored")
        func parsing() {
            #expect(HTTPAnswer.parseRetryAfter("120", now: now) == 120)
            #expect(HTTPAnswer.parseRetryAfter(" 7 ", now: now) == 7)
            #expect(HTTPAnswer.parseRetryAfter("1.5", now: now) == 1.5)
            #expect(HTTPAnswer.parseRetryAfter("0", now: now) == 0)
            #expect(HTTPAnswer.parseRetryAfter("Tue, 14 Nov 2023 22:15:20 GMT", now: now) == 120)
            #expect(HTTPAnswer.parseRetryAfter("Tue, 14 Nov 2023 22:00:00 GMT", now: now) == 0)    // in the past
            for bad in [nil, "", "soon", "-5", "inf", "nan", "Tue, 99 Foo 2023"] {
                #expect(HTTPAnswer.parseRetryAfter(bad, now: now) == nil, "\(bad ?? "nil")")
            }
        }

        @Test("a 429 or 503 without Retry-After falls back to X-RateLimit-Reset-In, other answers don't")
        func rateLimitHeader() {
            #expect(HTTPAnswer.retryDelay(status: 503, retryAfter: nil, rateLimitResetIn: "4", now: now) == 4)
            #expect(HTTPAnswer.retryDelay(status: 500, retryAfter: nil, rateLimitResetIn: "4", now: now) == nil)
            #expect(HTTPAnswer.retryDelay(status: 429, retryAfter: "30", rateLimitResetIn: "5", now: now) == 30)
            #expect(HTTPAnswer.retryDelay(status: 429, retryAfter: nil, rateLimitResetIn: "5", now: now) == 5)
            #expect(HTTPAnswer.retryDelay(status: 429, retryAfter: nil, rateLimitResetIn: nil, now: now) == nil)
            #expect(HTTPAnswer.retryDelay(status: 200, retryAfter: nil, rateLimitResetIn: "5", now: now) == nil)
            #expect(HTTPAnswer.retryDelay(status: 503, retryAfter: "10", rateLimitResetIn: nil, now: now) == 10)
        }

        @Test("the wait is what was asked for, 2 minutes at most, otherwise the backoff")
        func delay() {
            #expect(RetryDelay.delay(afterAttempt: 4, retryAfter: nil) == .seconds(8))
            #expect(RetryDelay.delay(afterAttempt: 4, retryAfter: 0) == .seconds(8))
            #expect(RetryDelay.delay(afterAttempt: 4, retryAfter: 2) == .seconds(2))
            #expect(RetryDelay.delay(afterAttempt: 1, retryAfter: 100) == .seconds(100))
            #expect(RetryDelay.delay(afterAttempt: 1, retryAfter: 120) == .seconds(120))
            #expect(RetryDelay.delay(afterAttempt: 1, retryAfter: 3600) == .seconds(120))
            #expect(RetryDelay.delay(afterAttempt: 1, retryAfter: 86_400) == .seconds(120))
        }
    }
}
