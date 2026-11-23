// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The way to one server (`SubsonicConnectionConfig`): makes the calls and decides which of the server's two addresses
/// they go to.
///
/// - One address: that is the one, always.
/// - Both: the local one is preferred. A `ping` to it is made when the connection starts and then every minute (and
///   when the network changes, `probe()`): while it answers, every call goes to it; when it doesn't, every call goes to
///   the public one (which is then pinged as well, so the status says whether the server can be reached at all). A call
///   that finds the address it was sent to unreachable tries the other one at once, and the connection stays with
///   whichever worked.
///
/// What happens is reported through `onActivity` (the last time the server was dealt with and whether that went
/// through), for the list in the Preferences. An answer that says "not found" counts as a success: the server is there.
@MainActor
final class SubsonicConnection {
    /// How often the local address is looked at.
    static let pingInterval: Duration = .seconds(60)

    /// The last thing that happened between the app and the server.
    struct Activity: Equatable {
        let date: Date
        /// nil: it went through.
        let error: SubsonicError?
        /// The address it was about.
        let route: SubsonicRoute?
    }

    private(set) var config: SubsonicConnectionConfig

    /// The address calls go to now; nil while the first ping is still out (with two addresses).
    private(set) var route: SubsonicRoute?

    /// Told about every call and ping. Set by whoever owns the connection.
    var onActivity: ((Activity) -> Void)?

    private let transport: any HTTPTransport
    private let pingTransport: any HTTPTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private var initialProbe: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var isProbing = false
    private var lastLoggedProblem: String?

    /// `config` is expected to be normalized. `pingTransport` is the one for the pings, which have to give up fast: an
    /// address that isn't there (the local one, somewhere else) must not hold anything up for long.
    init(config: SubsonicConnectionConfig,
         transport: any HTTPTransport = URLSessionTransport(timeout: SubsonicHTTP.requestTimeout),
         pingTransport: (any HTTPTransport)? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.config = config
        self.transport = transport
        self.pingTransport = pingTransport ?? URLSessionTransport(timeout: SubsonicHTTP.pingTimeout)
        self.sleep = sleep
        if config.routes.count == 1 { route = config.routes.first }
    }

    var name: String { config.displayName }

    /// Takes over settings that don't change how the server is reached (the name, the scrobbling switch).
    func updateSettings(_ new: SubsonicConnectionConfig) {
        guard new.hasSameConnection(as: config), new.id == config.id else { return }
        config = new
    }

    /// Starts the first ping and, with two addresses, the minute by minute checks.
    func start() {
        guard monitor == nil else { return }
        let first = Task<Void, Never> { [weak self] in
            if let self { await self.probe() }
        }
        initialProbe = first
        let twoRoutes = config.routes.count == 2
        let sleep = self.sleep
        monitor = Task { [weak self] in
            await first.value
            guard twoRoutes else { return }
            while !Task.isCancelled {
                do { try await sleep(Self.pingInterval) } catch { return }
                guard let self else { return }
                await self.probe()
            }
        }
    }

    /// Stops the checks. Calls that are on their way finish (or fail) by themselves.
    func stop() {
        initialProbe?.cancel()
        monitor?.cancel()
        initialProbe = nil
        monitor = nil
        onActivity = nil
    }

    // MARK: - Calls

    /// The URL of `method` at the address of `route`, nil if the connection has none of that kind.
    func url(_ method: String, _ params: [(String, String)] = [], route: SubsonicRoute) -> URL? {
        guard let endpoint = config.endpoint(route) else { return nil }
        return SubsonicAPI.url(endpoint: endpoint, method: method, username: config.username,
                               password: config.password, params: params)
    }

    /// The address the next call goes to: waits for the first ping if there is one on its way.
    func resolvedRoute() async -> SubsonicRoute? {
        if route == nil { await initialProbe?.value }
        return route ?? config.routes.first
    }

    /// What came of something that was sent to `route` from outside (a download): nil if it went through, then the
    /// connection stays with that address. An address that can't be reached makes the other one, if the connection has
    /// one, take over.
    func noteResult(_ error: SubsonicError?, on route: SubsonicRoute) {
        guard let error else {
            setRoute(route, because: nil)
            report(nil, route: route)
            return
        }
        if error.kind == .connection {
            if let other = config.routes.first(where: { $0 != route }), self.route == route {
                setRoute(other, because: "the \(route.title.lowercased()) address failed")
            }
            report(error, route: route)
        } else {
            report(error.kind == .authentication ? error : nil, route: route)
        }
    }

    /// Makes the call to `method` and returns what the server answers. An address that can't be reached is given up
    /// on for the other one.
    func call(_ method: String, _ params: [(String, String)] = []) async throws -> SubsonicResponse {
        try await attempt(method, params) { try SubsonicAPI.parse(status: $0.status, body: $0.body) }
    }

    /// Like `call` for a method that changes something on the server: sent as a POST with the parameters in the body (a
    /// long list of songs doesn't fit in a URL, and the credentials stay out of it). A server that doesn't take a POST
    /// there (405, 501) is asked with a GET instead.
    ///
    /// An address that can't be reached is given up on for the other one like with `call`; so a request that was
    /// received but whose answer got lost can be made twice (`createPlaylist` then makes two playlists).
    func write(_ method: String, _ params: [(String, String)] = []) async throws -> SubsonicResponse {
        do {
            return try await attempt(method, params, post: true) { try SubsonicAPI.parse(status: $0.status, body: $0.body) }
        } catch let error as SubsonicError where error == SubsonicError.postNotAccepted {
            Log.info("subsonic[\(name)]: the server doesn't take POST requests, using GET for \(method)")
            return try await call(method, params)
        }
    }

    /// Like `call` for a method that answers with a file (`getCoverArt`): the bytes of it.
    func data(_ method: String, _ params: [(String, String)] = []) async throws -> Data {
        try await attempt(method, params) { try SubsonicAPI.parseFile(status: $0.status, body: $0.body) }
    }

    /// The cover art `id` (of a song or an album), `size` pixels on the longer side at most; in the format the server has it in.
    func coverArt(_ id: String, size: Int? = nil) async throws -> Data {
        try await data("getCoverArt", [("id", id)] + (size.map { [("size", String($0))] } ?? []))
    }

    private func attempt<T>(_ method: String, _ params: [(String, String)], post: Bool = false,
                            interpret: (HTTPAnswer) throws -> T) async throws -> T {
        let first = await resolvedRoute()
        let order = config.routes.filter { $0 == first } + config.routes.filter { $0 != first }
        guard !order.isEmpty else { throw SubsonicError(.rejected, "the connection has no valid endpoint") }

        var failure = SubsonicError(.connection, "can't reach the server")
        for candidate in order {
            do {
                let result = try await send(method, params, on: candidate, using: transport, post: post, interpret: interpret)
                setRoute(candidate, because: route == candidate ? nil : "the \(candidate.title.lowercased()) address answers")
                report(nil, route: candidate)
                return result
            } catch let error as SubsonicError where error.kind == .connection {
                failure = error
            } catch let error as SubsonicError {
                // The server was reached and said no.
                report(error.kind == .authentication ? error : nil, route: candidate)
                throw error
            }
        }
        report(failure, route: order.last)
        throw failure
    }

    // MARK: - Testing

    /// What a `ping` to one address came to.
    struct RouteTest: Equatable {
        enum Outcome: Equatable {
            /// The server's description ("Navidrome 0.53.3 (API 1.16.1)").
            case success(String)
            case failure(SubsonicError)
        }

        let route: SubsonicRoute
        let outcome: Outcome
    }

    /// Pings every address of the connection, one after the other, and says what came of each. Doesn't touch what the
    /// connection is using, and isn't reported as activity.
    func test() async -> [RouteTest] {
        var results: [RouteTest] = []
        for route in config.routes {
            do {
                let response = try await send("ping", [], on: route, using: pingTransport)
                results.append(RouteTest(route: route, outcome: .success(SubsonicAPI.serverInfo(response))))
            } catch let error as SubsonicError {
                results.append(RouteTest(route: route, outcome: .failure(error)))
            } catch {
                results.append(RouteTest(route: route, outcome: .failure(SubsonicError(.connection, "cancelled"))))
                break
            }
        }
        return results
    }

    // MARK: - Looking at the addresses

    /// Looks at which address to use (see the top). With one address only checks that the server answers.
    func probe() async {
        guard !isProbing else { return }
        let routes = config.routes
        guard !routes.isEmpty else { return }
        isProbing = true
        defer { isProbing = false }

        if routes.count == 1 {
            let error = await ping(routes[0])
            guard !Task.isCancelled else { return }
            report(error, route: routes[0])
            return
        }
        if await ping(.local) == nil {
            guard !Task.isCancelled else { return }
            setRoute(.local, because: "the local address answers")
            report(nil, route: .local)
            return
        }
        guard !Task.isCancelled else { return }
        setRoute(.public, because: "the local address doesn't answer")
        let error = await ping(.public)
        guard !Task.isCancelled else { return }
        report(error, route: .public)
    }

    /// The error of a failed `ping` to `route`, nil if it went through.
    private func ping(_ route: SubsonicRoute) async -> SubsonicError? {
        do {
            _ = try await send("ping", [], on: route, using: pingTransport)
            return nil
        } catch let error as SubsonicError {
            return error
        } catch {
            return SubsonicError(.connection, "cancelled")
        }
    }

    // MARK: - Internals

    private func send(_ method: String, _ params: [(String, String)], on route: SubsonicRoute,
                      using transport: any HTTPTransport) async throws -> SubsonicResponse {
        try await send(method, params, on: route, using: transport) {
            try SubsonicAPI.parse(status: $0.status, body: $0.body)
        }
    }

    private func send<T>(_ method: String, _ params: [(String, String)], on route: SubsonicRoute,
                         using transport: any HTTPTransport, post: Bool = false,
                         interpret: (HTTPAnswer) throws -> T) async throws -> T {
        let request: URLRequest
        if post {
            guard let endpoint = config.endpoint(route), let url = SubsonicAPI.bareURL(endpoint: endpoint, method: method) else {
                throw SubsonicError(.rejected, "the \(route.title.lowercased()) endpoint isn't a valid URL")
            }
            var made = URLRequest(appURL: url, timeout: SubsonicHTTP.requestTimeout)
            made.httpMethod = "POST"
            made.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            made.httpBody = SubsonicAPI.formBody(username: config.username, password: config.password, params: params)
            request = made
        } else {
            guard let url = url(method, params, route: route) else {
                throw SubsonicError(.rejected, "the \(route.title.lowercased()) endpoint isn't a valid URL")
            }
            request = URLRequest(appURL: url, timeout: SubsonicHTTP.requestTimeout)
        }
        let answer: HTTPAnswer
        do {
            answer = try await transport.perform(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubsonicError(.connection, error.localizedDescription)
        }
        try Task.checkCancellation()
        if post, answer.status == 405 || answer.status == 501 { throw SubsonicError.postNotAccepted }
        return try interpret(answer)
    }

    private func setRoute(_ new: SubsonicRoute, because reason: String?) {
        guard route != new else { return }
        let old = route
        route = new
        guard config.routes.count == 2 else { return }
        Log.info("subsonic[\(name)]: using the \(new.title.lowercased()) address"
            + (old == nil ? "" : " (\(reason ?? "it works"))"))
    }

    private func report(_ error: SubsonicError?, route: SubsonicRoute?) {
        // The log says when something starts or stops being wrong, not every minute that it still is.
        let problem = error.map { "\($0.kind) \($0.message)" }
        if problem != lastLoggedProblem {
            if let error {
                Log.error("subsonic[\(name)]: \(route?.title.lowercased() ?? "the server"): \(error)")
            } else if lastLoggedProblem != nil {
                Log.info("subsonic[\(name)]: the server answers again")
            }
            lastLoggedProblem = problem
        }
        onActivity?(Activity(date: Date(), error: error, route: route))
    }
}

enum SubsonicHTTP {
    /// A call that takes longer than this is given up on.
    static let requestTimeout: TimeInterval = 30
    /// A ping that takes longer than this has failed: the address is not there.
    static let pingTimeout: TimeInterval = 6
}
