import SwiftUI

/// A drag of one item (a track in its album, an album among albums, a track of a flat playlist) to another place.
///
/// The items that can trade places (`range`) are all equally tall (`itemHeight`) and start at content offset `top`,
/// so everything is arithmetic: the dragged item is drawn wherever the pointer takes it (`drawnY`, kept inside the
/// range, only the vertical position changes), the slot it would land in is `target(forDrawnY:)`, and the items it
/// passes over move one slot out of its way (`shift(of:)`).
///
/// Indexes are those of the list that is shown while dragging: rows for `.track`, albums for `.album` (the playlist
/// is then shown collapsed to its album headers, `collapsed`).
struct ReorderDrag {
    enum Kind {
        /// A track row (of an album, or of a flat playlist); the list shown is the playlist as it is.
        case track
        /// An album header; the list shown has the headers only.
        case album
    }

    let kind: Kind
    /// Where the dragged item was, and the places it may be taken to.
    let from: Int
    let range: Range<Int>
    let itemHeight: CGFloat
    /// Content offset of the item at `range.lowerBound`.
    let top: CGFloat
    /// How far below the item's top edge the pointer took hold of it.
    let grab: CGFloat
    /// What the store needs to move it: a track's ID (the first track's for an album).
    let movedID: TrackID
    /// The geometry of the headers-only list shown while an album is dragged.
    let collapsed: PlaylistLayout?
    /// The slot it would land in right now.
    var target: Int
    /// Dropped; waiting for the playlist to show the new order.
    var settling = false

    /// Content offset of the top edge of slot `index`.
    func slotY(_ index: Int) -> CGFloat {
        top + CGFloat(index - range.lowerBound) * itemHeight
    }

    /// Where the dragged item's top edge is drawn for a pointer at content offset `pointerY`.
    func drawnY(pointerY: CGFloat) -> CGFloat {
        min(max(pointerY - grab, slotY(range.lowerBound)), slotY(range.upperBound - 1))
    }

    /// The slot nearest to an item whose top edge is at `y`.
    func target(forDrawnY y: CGFloat) -> Int {
        let slot = Int(((y - top) / itemHeight).rounded())
        return min(max(range.lowerBound + slot, range.lowerBound), range.upperBound - 1)
    }

    /// How far item `index` is moved from its place to make room for the dragged one.
    func shift(of index: Int) -> CGFloat {
        guard index != from, range.contains(index) else { return 0 }
        if from < target, index > from, index <= target { return -itemHeight }
        if from > target, index >= target, index < from { return itemHeight }
        return 0
    }
}

/// The vertical position of the dragged item. Observed on its own so that only the floating item is redrawn while
/// the pointer moves.
@Observable
final class DragPosition {
    var y: CGFloat = 0
}

/// What the drag handlers need to find again between events (plain references: changes don't re-render).
final class ReorderBox {
    enum Gesture {
        case idle
        /// The press began a drag.
        case active
        /// The press can't be a drag (or the drag was cancelled): ignore it until the button is released.
        case ignored
    }

    var gesture = Gesture.idle
    /// A drag is going on or has just ended: the click that ends the press isn't one.
    var suppressClicks = false
    /// What the timer does; set again on every render, so it sees the latest view value.
    var tick: (() -> Void)?
    private var timer: Timer?

    /// Calls `tick` 60 times a second (also while the pointer rests: the list scrolls when it is held at an edge).
    func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

/// The item being dragged, floating above the list at `position`.
struct DraggedItemOverlay<Content: View>: View {
    let position: DragPosition
    let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
            .offset(y: position.y)
            .allowsHitTesting(false)
    }
}
