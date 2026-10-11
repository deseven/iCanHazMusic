// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One part of the now playing block (`now_playing.top` / `now_playing.bottom` in the config; the raw value is what
/// the file holds). The order of the cases is the default order.
enum NowPlayingComponent: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The art of the playing album.
    case albumArt = "album_art"
    /// The first line of text, `{artist} – {title}` unless the user changed it (`now_playing.component_options.title`).
    case title
    /// The second line of text, `{album} ({year})` unless the user changed it (`now_playing.component_options.subtitle`).
    case subtitle
    /// `elapsed / total`.
    case duration
    case seekbar
    /// The codec line (and the lyrics button next to it).
    case details
    /// Previous album / track, play, pause, next, stop, and the random ones (the buttons are chosen in
    /// `now_playing.component_options.controls`).
    case controls
    case volume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .albumArt: "Album Art"
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .duration: "Duration"
        case .seekbar: "Seekbar"
        case .details: "Details"
        case .controls: "Playback Controls"
        case .volume: "Volume"
        }
    }

    /// Whether Preferences offers options of its own for it (the gear in the component list).
    var hasOptions: Bool {
        switch self {
        case .title, .subtitle, .seekbar, .controls: true
        default: false
        }
    }

    /// Where it is when nothing says otherwise (and where a component the config doesn't mention is put).
    var defaultSection: NowPlayingSection {
        switch self {
        case .controls, .volume: .bottom
        default: .top
        }
    }
}

/// The block has two stacks: the top one starts at the top edge, the bottom one is pinned to the bottom edge; the
/// space left over is between them.
enum NowPlayingSection: Sendable {
    case top
    case bottom
}

/// A component in one of the stacks, shown or hidden.
struct NowPlayingItem: Codable, Equatable, Identifiable, Sendable {
    var component: NowPlayingComponent
    var isVisible = true

    var id: NowPlayingComponent { component }

    enum CodingKeys: String, CodingKey {
        case component = "id"
        case isVisible = "visible"
    }

    init(_ component: NowPlayingComponent, isVisible: Bool = true) {
        self.component = component
        self.isVisible = isVisible
    }

    /// Throws for an id that isn't one of the components (the file may come from another version).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        component = try c.decode(NowPlayingComponent.self, forKey: .component)
        isVisible = (try? c.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? true
    }
}

/// Which components the now playing block has, in which order and in which of its two stacks.
///
/// Every component is in exactly one stack, once: whatever builds a layout from outside (the config file) is repaired
/// by `init(top:bottom:)`, and everything that changes one keeps it that way.
struct NowPlayingLayout: Equatable, Sendable {
    private(set) var top: [NowPlayingItem]
    private(set) var bottom: [NowPlayingItem]

    /// What `slots` is made of: the two stacks one after the other, with the boundary between them as an element of its own.
    enum Slot: Equatable, Sendable {
        case item(NowPlayingItem)
        case divider
    }

    static let `default` = NowPlayingLayout(top: [], bottom: [])

    /// A repaired layout: a component that comes twice stays where it is first (top stack first), and one that is
    /// not there at all is added, visible, at the end of its default stack.
    init(top: [NowPlayingItem], bottom: [NowPlayingItem]) {
        var seen = Set<NowPlayingComponent>()
        var top = top.filter { seen.insert($0.component).inserted }
        var bottom = bottom.filter { seen.insert($0.component).inserted }
        for component in NowPlayingComponent.allCases where !seen.contains(component) {
            switch component.defaultSection {
            case .top: top.append(NowPlayingItem(component))
            case .bottom: bottom.append(NowPlayingItem(component))
            }
        }
        self.top = top
        self.bottom = bottom
    }

    /// The inverse of `slots`; everything after the first divider is the bottom stack.
    init(slots: [Slot]) {
        var top: [NowPlayingItem] = []
        var bottom: [NowPlayingItem] = []
        var passedDivider = false
        for slot in slots {
            switch slot {
            case .divider: passedDivider = true
            case .item(let item): if passedDivider { bottom.append(item) } else { top.append(item) }
            }
        }
        self.init(top: top, bottom: bottom)
    }

    var slots: [Slot] {
        top.map(Slot.item) + [.divider] + bottom.map(Slot.item)
    }

    /// The components that are shown, in order.
    var visibleTop: [NowPlayingComponent] { top.filter(\.isVisible).map(\.component) }
    var visibleBottom: [NowPlayingComponent] { bottom.filter(\.isVisible).map(\.component) }

    func isVisible(_ component: NowPlayingComponent) -> Bool {
        (top + bottom).first { $0.component == component }?.isVisible ?? false
    }

    mutating func toggle(_ component: NowPlayingComponent) {
        if let index = top.firstIndex(where: { $0.component == component }) {
            top[index].isVisible.toggle()
        } else if let index = bottom.firstIndex(where: { $0.component == component }) {
            bottom[index].isVisible.toggle()
        }
    }

    /// Takes the component at slot `from` (see `slots`) to slot `to`: the one it moves into is where it ends up. Slot
    /// numbers count the divider; moving across it changes the stack. Does nothing for the divider itself or a slot
    /// that doesn't exist.
    mutating func move(from: Int, to: Int) {
        var slots = self.slots
        guard slots.indices.contains(from), slots.indices.contains(to), from != to,
              case .item = slots[from] else { return }
        slots.insert(slots.remove(at: from), at: to)
        self = NowPlayingLayout(slots: slots)
    }

    /// For the log: `top: album_art, title (hidden) | bottom: controls, volume`.
    var summary: String {
        func stack(_ items: [NowPlayingItem]) -> String {
            items.map { $0.isVisible ? $0.component.rawValue : "\($0.component.rawValue) (hidden)" }.joined(separator: ", ")
        }
        return "top: \(stack(top)) | bottom: \(stack(bottom))"
    }
}
