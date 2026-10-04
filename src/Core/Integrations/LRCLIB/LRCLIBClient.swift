import Foundation

/// LRCLIB lookups. Everything that goes wrong comes out as a `LRCLIBError` (or `CancellationError`).
struct LRCLIBClient: Sendable {
    let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionTransport(timeout: LRCLIBAPI.requestTimeout)) {
        self.transport = transport
    }

    /// One search; the lyrics of the record that is the track asked for, nil if LRCLIB has none.
    func lookup(_ query: LRCLIBQuery) async throws -> Lyrics? {
        let answer: HTTPAnswer
        do {
            answer = try await transport.perform(LRCLIBAPI.request(for: query))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No connection, a timeout, a reset...
            throw LRCLIBError(kind: .temporary, message: error.localizedDescription)
        }
        try Task.checkCancellation()
        return try LRCLIBAPI.match(for: query, in: LRCLIBAPI.check(answer))
    }
}
