// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What is shown on the user's Discord profile while a track plays: a "Listening" activity with the title, the
/// artist ("Listening to {artist}" in the member list), the album as the text of the image (the app icon) and the
/// start and end of the track, from which Discord draws the progress bar.
struct DiscordActivity: Equatable {
    /// The key of the image asset uploaded in the Discord Developer Portal (Rich Presence > Art Assets).
    static let imageKey = "icon"
    /// Discord's limits for the texts (in UTF-16 units, it's JavaScript).
    static let minLength = 2
    static let maxLength = 128
    /// The start or end may move this much (seconds) before it is worth telling Discord again.
    static let timeTolerance: TimeInterval = 2

    var title: String
    var artist: String
    var album: String?
    var start: Date
    var end: Date?

    /// The activity for `track` played `position` seconds in at `now`; nil for a track without tags, which is never
    /// shown (like it is never scrobbled). `duration` 0: unknown, there is no end then.
    init?(track: PlayedTrack, position: TimeInterval, duration: TimeInterval, now: Date = Date()) {
        guard track.hasTags,
              let title = Self.field(track.title),
              let artist = Self.field(track.artist) else { return nil }
        self.title = title
        self.artist = artist
        album = Self.field(track.album)
        start = now.addingTimeInterval(-max(position, 0))
        end = duration > 0 ? start.addingTimeInterval(duration) : nil
    }

    /// The same texts, and times close enough to not be worth an update.
    func isClose(to other: DiscordActivity) -> Bool {
        guard title == other.title, artist == other.artist, album == other.album,
              abs(start.timeIntervalSince(other.start)) <= Self.timeTolerance else { return false }
        switch (end, other.end) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= Self.timeTolerance
        default: return false
        }
    }

    /// `text` within Discord's limits: trimmed, too short ones padded with an invisible character, too long ones
    /// cut with an ellipsis. nil for an empty one.
    static func field(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.utf16.count < minLength { text += "\u{2800}" }   // braille blank, isn't trimmed by Discord
        guard text.utf16.count > maxLength else { return text }
        var cut = ""
        for character in text {
            guard cut.utf16.count + character.utf16.count <= maxLength - 1 else { break }
            cut.append(character)
        }
        return cut + "…"
    }

    var json: [String: Any] {
        var timestamps: [String: Any] = ["start": Self.milliseconds(start)]
        if let end { timestamps["end"] = Self.milliseconds(end) }
        var assets: [String: Any] = ["large_image": Self.imageKey]
        if let album { assets["large_text"] = album }
        return [
            "type": 2,                   // Listening
            "status_display_type": 1,    // "Listening to {state}" rather than to the app's name
            "details": title,
            "state": artist,
            "timestamps": timestamps,
            "assets": assets,
        ]
    }

    /// The `SET_ACTIVITY` command that shows `activity`, or clears what is shown for nil.
    static func command(_ activity: DiscordActivity?, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                        nonce: String = UUID().uuidString) -> Data {
        var args: [String: Any] = ["pid": Int(pid)]
        if let activity { args["activity"] = activity.json }
        let command: [String: Any] = ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce]
        // Only strings, numbers and dictionaries of them: can't fail.
        return (try? JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])) ?? Data()
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
