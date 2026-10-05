// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What came back for a request: the status line and the body, plus the one header the callers care about.
struct HTTPAnswer: Sendable {
    let status: Int
    let body: Data
    /// Seconds from a `Retry-After` header (the numeric form; a date is not understood), if there was one.
    var retryAfter: TimeInterval?

    init(status: Int, body: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Sends one HTTP request and returns the answer; abstracted so tests can answer instead of the real service.
protocol HTTPTransport: Sendable {
    /// Throws `CancellationError` if the task is cancelled, any other error for a failed connection.
    func perform(_ request: URLRequest) async throws -> HTTPAnswer
}

extension URLRequest {
    /// A request for `url` that identifies the app (`iCanHazMusic/{version}`) and gives up after `timeout` seconds.
    init(appURL url: URL, timeout: TimeInterval) {
        self.init(url: url, timeoutInterval: timeout)
        setValue(AppConstants.userAgent, forHTTPHeaderField: "User-Agent")
    }
}

/// The real thing. Every request has a hard limit of `timeout` seconds: the idle timeout of the request, and the
/// one for the whole transfer (which is what makes it hard).
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
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return HTTPAnswer(status: http?.statusCode ?? 0, body: data, retryAfter: retryAfter)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}
