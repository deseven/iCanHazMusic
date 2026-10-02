import Foundation

/// Sends one HTTP request and returns the status and body; abstracted so tests can answer instead of Last.fm.
protocol LastFMTransport: Sendable {
    /// Throws `CancellationError` if the task is cancelled, any other error for a failed connection.
    func perform(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

/// The real thing. Every request has a hard limit of `LastFMAPI.requestTimeout` seconds: the idle timeout of the
/// request, and the one for the whole transfer (which is what makes it hard).
struct URLSessionTransport: LastFMTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = LastFMAPI.requestTimeout
        configuration.timeoutIntervalForResource = LastFMAPI.requestTimeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func perform(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}

/// Last.fm calls. Everything that goes wrong comes out as a `LastFMError` (or `CancellationError`).
struct LastFMClient: Sendable {
    let credentials: LastFMCredentials
    let transport: any LastFMTransport

    init(credentials: LastFMCredentials, transport: any LastFMTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    /// Sends `call` (with `sessionKey` for the account methods) and returns the body of the answer.
    @discardableResult
    func send(_ call: LastFMCall, sessionKey: String? = nil) async throws -> Data {
        let request = LastFMAPI.request(for: call, credentials: credentials, sessionKey: sessionKey)
        let answer: (status: Int, body: Data)
        do {
            answer = try await transport.perform(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No connection, a timeout, a reset...
            throw LastFMError(kind: .temporary, code: nil, message: error.localizedDescription)
        }
        try Task.checkCancellation()
        return try LastFMAPI.check(status: answer.status, body: answer.body)
    }

    func getToken() async throws -> String {
        try LastFMAPI.parseToken(await send(.getToken()))
    }

    func getSession(token: String) async throws -> LastFMSession {
        try LastFMAPI.parseSession(await send(.getSession(token: token)))
    }
}
