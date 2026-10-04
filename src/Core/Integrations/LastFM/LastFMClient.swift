import Foundation


/// Last.fm calls. Everything that goes wrong comes out as a `LastFMError` (or `CancellationError`).
struct LastFMClient: Sendable {
    let credentials: LastFMCredentials
    let transport: any HTTPTransport

    init(credentials: LastFMCredentials, transport: any HTTPTransport = URLSessionTransport(timeout: LastFMAPI.requestTimeout)) {
        self.credentials = credentials
        self.transport = transport
    }

    /// Sends `call` (with `sessionKey` for the account methods) and returns the body of the answer.
    @discardableResult
    func send(_ call: LastFMCall, sessionKey: String? = nil) async throws -> Data {
        let request = LastFMAPI.request(for: call, credentials: credentials, sessionKey: sessionKey)
        let answer: HTTPAnswer
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
