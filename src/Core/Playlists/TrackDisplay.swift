// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// What the user is shown for a track whose tags are missing. The data holds an empty string there (see `TagFallback`),
// so everything that is shown (playlist, queue, search, notifications, the Dock menu, the system's Now Playing, the
// log) goes through these, and everything that is sent somewhere (scrobbling, lyrics) takes the data as it is.

extension Track {
    /// "Unknown Artist" if the track has no artist.
    var displayArtist: String { TagFallback.shownArtist(artist) }

    /// The title; the name of the file if the track has none ("Unknown Track" for a part of a file, which has no name).
    var displayTitle: String { TagFallback.shownTitle(title, file: cue == nil ? url : nil) }
}

extension Album {
    /// "Unknown Artist" if the album has no artist.
    var displayArtist: String { TagFallback.shownArtist(artist) }

    /// "Unknown Album" if the album has no title.
    var displayTitle: String { TagFallback.shownAlbum(title) }
}

extension TrackEntry {
    var displayArtist: String { TagFallback.shownArtist(artist) }
    var displayTitle: String { TagFallback.shownTitle(title, file: cue == nil ? url : nil) }
}
