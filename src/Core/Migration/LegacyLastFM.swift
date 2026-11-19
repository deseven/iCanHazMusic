// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What is left of the Last.fm integration, which is gone: Last.fm makes its API keys paid, so the app can't have
/// one. People scrobble to Last.fm (the legacy Audioscrobbler protocol) or ListenBrainz through the scrobbling
/// services now. A config that still has a Last.fm login is recognized here, the login is dropped by loading it
/// (`ConfigStore`), and the user is told once (`LastFMRemovalNotice`).
enum LegacyLastFM {
    /// Last.fm's announcement that API keys will need a PRO subscription.
    static let announcementURL = URL(string: "https://support.last.fm/t/api-keys-will-require-pro-from-1st-december/121030")!

    /// What is remembered of the login that was removed. The session key itself is useless (the legacy protocol needs
    /// the password, which was never kept), only the name of the account is of use.
    struct Login: Equatable {
        var username: String?

        init(username: String?) {
            let trimmed = username?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.username = trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    /// The login in the raw `config.json` (a session in `integrations.lastfm`); nil if there is none.
    static func login(inConfig data: Data) -> Login? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let integrations = root["integrations"] as? [String: Any],
              let lastfm = integrations["lastfm"] as? [String: Any],
              let session = lastfm["session"] as? String, !session.isEmpty else { return nil }
        return Login(username: lastfm["username"] as? String)
    }

    /// The Audioscrobbler service that takes the place of the login: Last.fm's server, the account name if it is known,
    /// and no password (it has to be typed in).
    static func suggestedService(for login: Login) -> ScrobbleServiceConfig {
        ScrobbleServiceConfig(name: "Last.fm", type: .audioscrobbler, endpoint: ScrobbleServiceConfig.lastFMEndpoint,
                              username: login.username ?? "")
    }
}
