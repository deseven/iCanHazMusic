import Foundation
@testable import iCanHazMusic

/// Stands in for the network: `handler` answers every request (it also decides for how long, and whether, to fail).
final class HTTPStub: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, _ index: Int) async throws -> HTTPAnswer

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    convenience init(always answer: HTTPAnswer) {
        self.init { _, _ in answer }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    /// The `track_name` of every request received so far.
    var titles: [String] { requests.compactMap { Self.query(of: $0)["track_name"] } }

    func perform(_ request: URLRequest) async throws -> HTTPAnswer {
        let index = lock.withLock { () -> Int in
            recorded.append(request)
            return recorded.count - 1
        }
        return try await handler(request, index)
    }

    static func query(of request: URLRequest) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }
}

/// Answers LRCLIB gives.
enum LRCLIBAnswer {
    static func records(_ records: [[String: Any]]) -> HTTPAnswer {
        HTTPAnswer(status: 200, body: (try? JSONSerialization.data(withJSONObject: records)) ?? Data())
    }

    /// A record for what the request searches for.
    static func found(for request: URLRequest, plain: String = "text") -> HTTPAnswer {
        let query = HTTPStub.query(of: request)
        return records([record(artist: query["artist_name"] ?? "", title: query["track_name"] ?? "", plain: plain)])
    }

    static let none = records([])
    static let serverError = HTTPAnswer(status: 500, body: Data("<html>oops</html>".utf8))
    static let notFound = HTTPAnswer(status: 404, body: Data(#"{"code":404,"name":"NotFound","message":"nope"}"#.utf8))

    static func tooManyRequests(retryAfter: TimeInterval? = nil) -> HTTPAnswer {
        HTTPAnswer(status: 429, body: Data(), retryAfter: retryAfter)
    }

    /// A record of the search answer.
    static func record(artist: String = "Artist", title: String = "Title", album: String = "Album",
                       duration: TimeInterval = 200, plain: String? = "la la la", synced: String? = nil,
                       instrumental: Bool = false) -> [String: Any] {
        var record: [String: Any] = [
            "id": 1, "name": title, "trackName": title, "artistName": artist, "albumName": album,
            "duration": duration, "instrumental": instrumental,
        ]
        record["plainLyrics"] = plain ?? NSNull()
        record["syncedLyrics"] = synced ?? NSNull()
        return record
    }
}

/// A sleep that blocks the first time it is asked to wait, until `release()`; after that nothing waits.
final class GatedSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: CheckedContinuation<Void, Never>?
    private var released = false

    var waiting: Bool { lock.withLock { blocked != nil } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    if released { continuation.resume() } else { blocked = continuation }
                }
            }
        }
    }

    func release() {
        lock.withLock {
            released = true
            blocked?.resume()
            blocked = nil
        }
    }
}

enum LRCLIBTestData {
    static let query = LRCLIBQuery(artist: "Artist", title: "Title", album: "Album", duration: 200)

    static func query(title: String) -> LRCLIBQuery {
        LRCLIBQuery(artist: "Artist", title: title, album: "Album", duration: 200)
    }

    static func track(artist: String = "Artist", title: String = "Title", album: String = "Album",
                      duration: TimeInterval = 200, startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> PlayedTrack {
        PlayedTrack(artist: artist, title: title, album: album, duration: duration, startedAt: startedAt)
    }
}
