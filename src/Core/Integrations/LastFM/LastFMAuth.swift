// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The desktop authorization flow of Last.fm (https://www.last.fm/api/authspec):
///
/// 1. get a token (`auth.getToken`),
/// 2. send the user to Last.fm to confirm that the app may use their account (`openURL`),
/// 3. ask for a session for the token (`auth.getSession`) until it is granted. Last.fm answers with error 14 as long
///    as the user hasn't confirmed, so this is done every `pollInterval`, and right away when the app comes back
///    to the front (`checkNow`): that is when the user has most likely just confirmed.
///
/// Cancel the task running `run()` to abort; nothing is kept then.
@MainActor
final class LastFMAuth {
    enum Outcome: Equatable {
        case connected(LastFMSession)
        case aborted
        case failed(String)
    }

    nonisolated static let defaultPollInterval: Duration = .seconds(5)

    private let client: LastFMClient
    private let openURL: (URL) -> Void
    private let pollInterval: Duration
    private let wakeUps: AsyncStream<Void>
    private let wakeUp: AsyncStream<Void>.Continuation

    init(client: LastFMClient, pollInterval: Duration = LastFMAuth.defaultPollInterval, openURL: @escaping (URL) -> Void) {
        self.client = client
        self.pollInterval = pollInterval
        self.openURL = openURL
        (wakeUps, wakeUp) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Asks Last.fm now instead of at the next interval.
    func checkNow() {
        wakeUp.yield()
    }

    func run() async -> Outcome {
        let token: String
        do {
            token = try await client.getToken()
        } catch is CancellationError {
            return .aborted
        } catch {
            Log.error("last.fm: can't get an auth token: \(error)")
            return .failed("Couldn't get an authorization token from Last.fm:\n\(error)")
        }

        Log.info("last.fm: waiting for the authorization to be confirmed")
        openURL(LastFMAPI.authorizationURL(credentials: client.credentials, token: token))

        let interval = pollInterval
        let wakeUp = self.wakeUp
        let timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                wakeUp.yield()
            }
        }
        defer { timer.cancel() }

        // The stream ends when the task is cancelled.
        for await _ in wakeUps {
            do {
                let session = try await client.getSession(token: token)
                Log.info("last.fm: connected as \(session.username)")
                return .connected(session)
            } catch is CancellationError {
                return .aborted
            } catch let error as LastFMError {
                if error.code == LastFMError.tokenNotAuthorizedCode || error.kind == .temporary { continue }
                Log.error("last.fm: authorization failed: \(error)")
                return .failed("Last.fm didn't grant access:\n\(error)")
            } catch {
                return .aborted
            }
        }
        return .aborted
    }
}
