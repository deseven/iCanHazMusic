import SwiftUI

/// Playlist + divider + playback block. Owns the width arithmetic of the right-hand block.
struct PlayerArea: View {
    private let playback = PlaybackState.shared
    private let store = PlaylistStore.shared

    /// Selected rows of the active playlist (reset when another playlist is opened, to its last played track).
    @State private var selection: Set<Int> = []
    /// A row the playlist view is asked to scroll to; it resets this once it has.
    @State private var revealRow: Int?

    /// Width the user asked for by dragging the divider. The effective width is this value
    /// clamped to what the current window size allows (so it "comes back" when the window grows).
    @State private var preferredBlockWidth: CGFloat

    /// Height of everything below the album art, measured from the real view.
    @State private var controlsHeight: CGFloat = 200

    init() {
        _preferredBlockWidth = State(initialValue: CGFloat(ConfigStore.shared.config.ui.playbackStatusWidth))
    }

    var body: some View {
        GeometryReader { geo in
            let range = blockWidthRange(in: geo.size)
            let blockWidth = min(max(preferredBlockWidth, range.lowerBound), range.upperBound)

            HStack(spacing: 0) {
                PlaylistView(selection: $selection, cursor: Bindable(playback).cursorRow, revealRow: $revealRow)
                    .frame(minWidth: Layout.playlistMinWidth, maxWidth: .infinity, maxHeight: .infinity)

                SplitDivider(
                    width: Binding(get: { blockWidth }, set: { preferredBlockWidth = $0 }),
                    range: range
                )

                PlaybackBlock(state: playback,
                              playFromSelection: playFromSelection,
                              hasSelection: !selection.isEmpty,
                              controlsHeight: $controlsHeight)
                    .frame(width: blockWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: Layout.playlistMinWidth + Layout.dividerLineWidth + Layout.blockMinWidth)
        .onChange(of: store.activeName) { _, _ in
            // Rows of the old playlist mean nothing in the new one, which is still being read. (One that is ready
            // at once is dealt with by `playlistOpened`.)
            guard store.isLoading else { return }
            selection = []
            playback.placeCursor(at: nil)
        }
        .onChange(of: store.openCount) { _, _ in playlistOpened() }
        .onAppear {
            if !store.isLoading { playlistOpened() }   // the playlist was ready before this view was
        }
        .onChange(of: preferredBlockWidth) { _, width in
            ConfigStore.shared.update { $0.ui.playbackStatusWidth = Int(width.rounded()) }
        }
    }

    /// A playlist has been opened (also at launch): its last played track, which is the playing one while playback
    /// runs from it, is selected and scrolled to; if there is none, nothing is selected. This is just a convenience:
    /// it doesn't depend on `cursorFollowsPlayback`, and the cursor is placed there without asking playback to go
    /// to it (`playbackFollowsCursor`). A row the search asked to go to (`PlaylistStore.reveal`) comes first.
    private func playlistOpened() {
        let row = store.takeReveal() ?? playback.playingRow ?? store.lastPlayedRow
        selection = row.map { [$0] } ?? []
        playback.placeCursor(at: row)
        revealRow = row
    }

    /// Starts at the first selected row (an album header starts its first track).
    private func playFromSelection() {
        guard let row = selection.min() else { return }
        playback.play(row: row)
    }

    /// Allowed block width for the given area:
    /// - min: album art at its minimum size
    /// - max: whichever is smaller of "leave the playlist its minimum" and
    ///   "album art can't get taller than the block content allows" (art is square, so the
    ///   height limit is also a width limit; widening beyond it would only add empty space).
    private func blockWidthRange(in size: CGSize) -> ClosedRange<CGFloat> {
        let pad = Layout.blockPadding
        let maxArtByHeight = size.height - controlsHeight - Layout.artToControlsGap - 2 * pad
        let maxByHeight = maxArtByHeight + 2 * pad
        let maxByPlaylist = size.width - Layout.playlistMinWidth - Layout.dividerLineWidth
        let lower = Layout.blockMinWidth
        let upper = max(lower, min(maxByHeight, maxByPlaylist, Layout.blockMaxWidth))
        return lower...upper
    }
}
