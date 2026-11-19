// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What came back for a request: the status line and the body, plus the one header the callers care about.
struct HTTPAnswer: Sendable {
    let status: Int
    let body: Data
    /// How many seconds the server asks to wait before the next request, nil if it doesn't say. That is the
    /// standard `Retry-After` header (seconds or a date; LRCLIB documents it, MetaBrainz doesn't mention it), or for
    /// a 429/503 without one MetaBrainz's own `X-RateLimit-Reset-In` (what their docs tell clients to use).
    var retryAfter: TimeInterval?

    init(status: Int, body: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

extension HTTPAnswer {
    /// The wait a response asks for, see `retryAfter`. `X-RateLimit-Reset-In` is sent with every MetaBrainz answer
    /// (it is when the current window ends), so it only counts for the answers that say "not now": 429 and 503.
    static func retryDelay(status: Int, retryAfter: String?, rateLimitResetIn: String?, now: Date = Date()) -> TimeInterval? {
        let busy = status == 429 || status == 503
        return parseRetryAfter(retryAfter, now: now) ?? (busy ? parseRetryAfter(rateLimitResetIn, now: now) : nil)
    }

    /// A `Retry-After` value: a number of seconds, or an HTTP date (then the seconds from `now`, 0 if it is past).
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds.isFinite && seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Sends one HTTP request and returns the answer; abstracted so tests can answer instead of the real service.
protocol HTTPTransport: Sendable {
    /// Throws `CancellationError` if the task is cancelled, any other error for a failed connection.
    func perform(_ request: URLRequest) async throws -> HTTPAnswer
}

extension AppConstants {
    /// The `User-Agent` for a request to `url`: `iCanHazMusic/{version}`, and for MetaBrainz hosts (which require a
    /// way to contact the app's author) `iCanHazMusic/{version} ({contact URL})`. Other hosts never see the contact.
    static func userAgent(for url: URL) -> String {
        isMetaBrainzHost(url.host) ? "\(userAgent) (\(contactURL))" : userAgent
    }

    /// A broad match on purpose, so that new services and subdomains are covered: everything under `*brainz.org`
    /// (musicbrainz, listenbrainz, metabrainz, bookbrainz, critiquebrainz, acousticbrainz, with any subdomain such as
    /// `api.listenbrainz.org`, `beta.musicbrainz.org`, `labs.api.listenbrainz.org`).
    /// A self-hosted ListenBrainz-compatible server is not matched.
    static func isMetaBrainzHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        return name.hasSuffix("brainz.org")
    }
}

extension URLRequest {
    /// A request for `url` that identifies the app (`iCanHazMusic/{version}`, plus the contact URL for MetaBrainz
    /// hosts) and gives up after `timeout` seconds.
    init(appURL url: URL, timeout: TimeInterval) {
        self.init(url: url, timeoutInterval: timeout)
        setValue(AppConstants.userAgent(for: url), forHTTPHeaderField: "User-Agent")
    }
}

/// The real thing. Every request has a hard limit of `timeout` seconds: the idle timeout of the request, and the
/// one for the whole transfer (which is what makes it hard). Requests to MetaBrainz hosts are spaced out to what
/// their rate limit allows (`RequestSpacer.metaBrainz`); the time spent waiting for the turn is not part of the limit.
struct URLSessionTransport: HTTPTransport {
    static let defaultTimeout: TimeInterval = 30

    private let session: URLSession

    init(timeout: TimeInterval = URLSessionTransport.defaultTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func perform(_ request: URLRequest) async throws -> HTTPAnswer {
        if AppConstants.isMetaBrainzHost(request.url?.host) { try await RequestSpacer.metaBrainz.wait() }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let retryAfter = http.flatMap {
                HTTPAnswer.retryDelay(status: $0.statusCode,
                                      retryAfter: $0.value(forHTTPHeaderField: "Retry-After"),
                                      rateLimitResetIn: $0.value(forHTTPHeaderField: "X-RateLimit-Reset-In"))
            }
            return HTTPAnswer(status: http?.statusCode ?? 0, body: data, retryAfter: retryAfter)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}
