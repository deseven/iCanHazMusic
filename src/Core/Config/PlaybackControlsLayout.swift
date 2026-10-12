// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One button of the Playback Controls component (`now_playing.component_options.controls` in the config; the raw
/// value is what the file holds). The order of the cases is the default order.
enum PlaybackControl: String, Codable, CaseIterable, Identifiable, Sendable {
    case previousAlbum = "previous_album"
    case previousTrack = "previous_track"
    /// Play while paused (or stopped), pause while playing.
    case playPause = "play_pause"
    case nextTrack = "next_track"
    case nextAlbum = "next_album"
    case stop
    /// Plays a random track, whatever the playback order is.
    case randomTrack = "random_track"
    /// Plays the first track of a random album, whatever the playback order is.
    case randomAlbum = "random_album"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previousAlbum: "Previous Album"
        case .previousTrack: "Previous Track"
        case .playPause: "Play / Pause"
        case .nextTrack: "Next Track"
        case .nextAlbum: "Next Album"
        case .stop: "Stop"
        case .randomTrack: "Random Track"
        case .randomAlbum: "Random Album"
        }
    }

    /// Shown when nothing says otherwise (and when the config doesn't mention the button).
    var isVisibleByDefault: Bool {
        switch self {
        case .randomTrack, .randomAlbum: false
        default: true
        }
    }
}

/// A button, shown or hidden.
struct PlaybackControlItem: Codable, Equatable, Identifiable, Sendable {
    var control: PlaybackControl
    var isVisible: Bool

    var id: PlaybackControl { control }

    enum CodingKeys: String, CodingKey {
        case control = "id"
        case isVisible = "visible"
    }

    init(_ control: PlaybackControl, isVisible: Bool? = nil) {
        self.control = control
        self.isVisible = isVisible ?? control.isVisibleByDefault
    }

    /// Throws for an id that isn't one of the buttons (the file may come from another version).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        control = try c.decode(PlaybackControl.self, forKey: .control)
        isVisible = (try? c.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? control.isVisibleByDefault
    }
}

/// Which buttons the Playback Controls component has, in which order, and which of them are shown.
///
/// Every button is in the list exactly once: whatever builds a layout from outside (the config file) is repaired by
/// `init(items:)`, and everything that changes one keeps it that way.
struct PlaybackControlsLayout: Codable, Equatable, Sendable {
    private(set) var items: [PlaybackControlItem]

    static let `default` = PlaybackControlsLayout(items: [])

    /// A repaired layout: a button that comes twice stays where it is first, and one that is not there at all is
    /// added, as visible as it is by default, at the end.
    init(items: [PlaybackControlItem]) {
        var seen = Set<PlaybackControl>()
        var items = items.filter { seen.insert($0.control).inserted }
        for control in PlaybackControl.allCases where !seen.contains(control) {
            items.append(PlaybackControlItem(control))
        }
        self.items = items
    }

    /// The entries that can't be read are left out (`init(items:)` puts back what is missing).
    init(from decoder: Decoder) throws {
        let entries = try decoder.singleValueContainer().decode([Lossy<PlaybackControlItem>].self)
        self.init(items: entries.compactMap(\.value))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(items)
    }

    /// The buttons that are shown, in order.
    var visible: [PlaybackControl] { items.filter(\.isVisible).map(\.control) }

    func isVisible(_ control: PlaybackControl) -> Bool {
        items.first { $0.control == control }?.isVisible ?? false
    }

    mutating func toggle(_ control: PlaybackControl) {
        guard let index = items.firstIndex(where: { $0.control == control }) else { return }
        items[index].isVisible.toggle()
    }

    /// Takes the button at index `from` to index `to`: the one it moves into is where it ends up. Does nothing for an
    /// index that doesn't exist.
    mutating func move(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return }
        items.insert(items.remove(at: from), at: to)
    }

    /// For the log: `previous_album, play_pause, random_track (hidden)`.
    var summary: String {
        items.map { $0.isVisible ? $0.control.rawValue : "\($0.control.rawValue) (hidden)" }.joined(separator: ", ")
    }
}

/// Decodes a list entry without failing the whole list when the entry is not one that can be read.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
