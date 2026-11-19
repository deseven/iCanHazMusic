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

    /// The raw `config.json` has a session in `integrations.lastfm`.
    static func isConfigured(inConfig data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let integrations = root["integrations"] as? [String: Any],
              let lastfm = integrations["lastfm"] as? [String: Any],
              let session = lastfm["session"] as? String else { return false }
        return !session.isEmpty
    }
}
