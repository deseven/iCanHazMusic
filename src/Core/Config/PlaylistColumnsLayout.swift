// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// How a playlist is shown: grouped by albums, or as one flat list. Each has its own columns.
enum PlaylistMode: String, CaseIterable, Identifiable, Sendable {
    case album
    case flat

    init(isFlat: Bool) {
        self = isFlat ? .flat : .album
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .album: "Album Mode"
        case .flat: "Flat Mode"
        }
    }
}

/// One column of the track rows of a playlist (`playlist.album_columns` / `playlist.flat_columns` in the config; the
/// raw value is what the file holds). The order of the cases is the default order.
enum PlaylistColumn: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The play symbol of the playing track, or the place of a queued one in the queue.
    case status
    case number
    /// Grows to take the room the others leave.
    case title
    case duration
    /// The lyrics button (if the track has lyrics), then the codec.
    case details

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "Status"
        case .number: "Track Number"
        case .title: "Title"
        case .duration: "Duration"
        case .details: "Details"
        }
    }

    /// Shown when nothing says otherwise (and when the config doesn't mention the column).
    func isVisibleByDefault(in mode: PlaylistMode) -> Bool {
        !(self == .number && mode == .flat)
    }
}

/// A column, shown or hidden.
struct PlaylistColumnItem: Codable, Equatable, Identifiable, Sendable {
    var column: PlaylistColumn
    var isVisible: Bool

    var id: PlaylistColumn { column }

    enum CodingKeys: String, CodingKey {
        case column = "id"
        case isVisible = "visible"
    }

    init(_ column: PlaylistColumn, isVisible: Bool) {
        self.column = column
        self.isVisible = isVisible
    }
}

/// Which columns the track rows of one `PlaylistMode` have, in which order, and which of them are shown.
///
/// Every column is in the list exactly once: whatever builds a layout from outside (the config file) is repaired by
/// `init(mode:items:)`, and everything that changes one keeps it that way.
struct PlaylistColumnsLayout: Encodable, Equatable, Sendable {
    let mode: PlaylistMode
    private(set) var items: [PlaylistColumnItem]

    static func `default`(_ mode: PlaylistMode) -> PlaylistColumnsLayout {
        PlaylistColumnsLayout(mode: mode, items: [])
    }

    /// A repaired layout: a column that comes twice stays where it is first, and one that is not there at all is
    /// added, as visible as it is by default in `mode`, at the end.
    init(mode: PlaylistMode, items: [PlaylistColumnItem]) {
        self.mode = mode
        var seen = Set<PlaylistColumn>()
        var items = items.filter { seen.insert($0.column).inserted }
        for column in PlaylistColumn.allCases where !seen.contains(column) {
            items.append(PlaylistColumnItem(column, isVisible: column.isVisibleByDefault(in: mode)))
        }
        self.items = items
    }

    /// Only the list goes to the file: the mode is the key it is stored under.
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(items)
    }

    var isDefault: Bool { self == .default(mode) }

    /// The columns that are shown, in order.
    var visible: [PlaylistColumn] { items.filter(\.isVisible).map(\.column) }

    func isVisible(_ column: PlaylistColumn) -> Bool {
        items.first { $0.column == column }?.isVisible ?? false
    }

    mutating func toggle(_ column: PlaylistColumn) {
        guard let index = items.firstIndex(where: { $0.column == column }) else { return }
        items[index].isVisible.toggle()
    }

    /// Takes the column at index `from` to index `to`: the one it moves into is where it ends up. Does nothing for an
    /// index that doesn't exist.
    mutating func move(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return }
        items.insert(items.remove(at: from), at: to)
    }

    /// For the log: `status, title, number (hidden)`.
    var summary: String {
        items.map { $0.isVisible ? $0.column.rawValue : "\($0.column.rawValue) (hidden)" }.joined(separator: ", ")
    }
}
