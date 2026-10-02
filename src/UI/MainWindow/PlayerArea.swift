import SwiftUI

/// Playlist + divider + playback block. Owns the width arithmetic of the right-hand block.
struct PlayerArea: View {
    private let playback = PlaybackState.shared
    private let store = PlaylistStore.shared

    /// Selected rows of the active playlist (reset when another playlist is shown).
    @State private var selection: Set<Int> = []

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
                PlaylistView(selection: $selection, cursor: Bindable(playback).cursorRow)
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
            selection = []
            playback.cursorRow = nil
        }
        .onChange(of: preferredBlockWidth) { _, width in
            ConfigStore.shared.update { $0.ui.playbackStatusWidth = Int(width.rounded()) }
        }
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
