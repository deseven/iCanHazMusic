// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// [ playlist selector ] [ playlist ] [ now playing block ], or the other way round when they are swapped
/// (`WindowSettings.swapsSides`). Both side panels are `SidePanel`s: shown and hidden with their toolbar buttons, slid
/// in and out the same way, resized with their dividers. Owns the width arithmetic of both.
struct PlayerArea: View {
    private let playback = PlaybackState.shared
    private let store = PlaylistStore.shared
    private let nowPlaying = NowPlayingSettings.shared
    private let windowSettings = WindowSettings.shared

    /// Selected rows of the active playlist (reset when another playlist is opened, to its last played track).
    @State private var selection: Set<Int> = []
    /// A row the playlist view is asked to scroll to; it resets this once it has.
    @State private var revealRow: Int?
    /// The playlist whose opening is complete: its content is in and scrolled to its row. Until it is the active one
    /// the playlist is hidden behind a spinner, so the user doesn't see it being filled and scrolled.
    @State private var openedName: String?

    /// Widths the user asked for by dragging the dividers. The effective widths are these values
    /// clamped to what the current window size allows (so they "come back" when the window grows).
    @State private var preferredSelectorWidth: CGFloat
    @State private var preferredBlockWidth: CGFloat

    /// Height of everything in the block but the album art, measured from the real view.
    @State private var controlsHeight: CGFloat = 200

    init() {
        let ui = ConfigStore.shared.config.ui
        _preferredSelectorWidth = State(initialValue: CGFloat(ui.playlistSelector.width))
        _preferredBlockWidth = State(initialValue: CGFloat(ui.nowPlaying.width))
    }

    var body: some View {
        let showsSelector = windowSettings.showsPlaylistSelector
        let showsBlock = nowPlaying.isShown
        let swapped = windowSettings.swapsSides
        let selectorEdge: HorizontalEdge = swapped ? .trailing : .leading
        let blockEdge: HorizontalEdge = swapped ? .leading : .trailing
        GeometryReader { geo in
            let selectorRange = selectorWidthRange(in: geo.size, withBlock: showsBlock)
            let selectorWidth = min(max(preferredSelectorWidth, selectorRange.lowerBound), selectorRange.upperBound)
            let selectorRoom = showsSelector ? selectorWidth + Layout.dividerLineWidth : 0
            let blockRange = blockWidthRange(in: CGSize(width: geo.size.width - selectorRoom, height: geo.size.height))
            let blockWidth = min(max(preferredBlockWidth, blockRange.lowerBound), blockRange.upperBound)

            HStack(spacing: 0) {
                if showsSelector && selectorEdge == .leading {
                    selectorPanel(edge: .leading, width: selectorWidth, range: selectorRange)
                }
                if showsBlock && blockEdge == .leading {
                    blockPanel(edge: .leading, width: blockWidth, range: blockRange)
                }

                Group {
                    if store.isQueueShown && playback.queue.isEnabled {
                        QueueView()
                    } else {
                        PlaylistView(selection: $selection, cursor: Bindable(playback).cursorRow, revealRow: $revealRow)
                            .overlay {
                                if openedName != store.activeName { OpeningCover() }
                            }
                    }
                }
                .frame(minWidth: Layout.playlistMinWidth, maxWidth: .infinity, maxHeight: .infinity)

                if showsBlock && blockEdge == .trailing {
                    blockPanel(edge: .trailing, width: blockWidth, range: blockRange)
                }
                if showsSelector && selectorEdge == .trailing {
                    selectorPanel(edge: .trailing, width: selectorWidth, range: selectorRange)
                }
            }
            .clipped()   // a sliding panel is partly outside the area
            .animation(Layout.sidePanelAnimation, value: showsSelector)
            .animation(Layout.sidePanelAnimation, value: showsBlock)
            .animation(Layout.sidePanelAnimation, value: swapped)
        }
        .frame(minWidth: minWidth(showsSelector: showsSelector, showsBlock: showsBlock))
        .onChange(of: store.activeName) { _, _ in
            // Rows of the old playlist mean nothing in the new one, which is still being read. (One that is ready
            // at once is dealt with by `playlistOpened`.)
            guard store.isLoading else { return }
            selection = []
            playback.placeCursor(at: nil)
        }
        .onChange(of: store.openCount) { _, _ in playlistOpened() }
        .onChange(of: revealRow) { _, row in
            if row == nil { finishOpening() }   // the view has scrolled to the row
        }
        .task(id: store.activeName) {
            // Safety net: the view must never stay hidden if it didn't report back.
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { finishOpening(after: .zero) }
        }
        .onChange(of: playback.queue.isEnabled) { _, enabled in
            if !enabled { store.hideQueue() }   // the queue view has nothing to show any more
        }
        .onAppear {
            if !store.isLoading { playlistOpened() }   // the playlist was ready before this view was
        }
        .onChange(of: preferredSelectorWidth) { _, width in
            ConfigStore.shared.update { $0.ui.playlistSelector.width = Int(width.rounded()) }
        }
        .onChange(of: preferredBlockWidth) { _, width in
            ConfigStore.shared.update { $0.ui.nowPlaying.width = Int(width.rounded()) }
        }
    }

    private func selectorPanel(edge: HorizontalEdge, width: CGFloat, range: ClosedRange<CGFloat>) -> some View {
        SidePanel(edge: edge, width: Binding(get: { width }, set: { preferredSelectorWidth = $0 }), range: range) {
            PlaylistSelector()
        }
        .sidePanelTransition(edge)
    }

    private func blockPanel(edge: HorizontalEdge, width: CGFloat, range: ClosedRange<CGFloat>) -> some View {
        SidePanel(edge: edge, width: Binding(get: { width }, set: { preferredBlockWidth = $0 }), range: range) {
            NowPlayingBlock(state: playback,
                            playFromSelection: playFromSelection,
                            hasSelection: !selection.isEmpty || playback.hasQueuedTracks,
                            controlsHeight: $controlsHeight)
        }
        .sidePanelTransition(edge)
    }

    /// The playlist at its minimum, and each panel that is shown at its minimum with its divider.
    private func minWidth(showsSelector: Bool, showsBlock: Bool) -> CGFloat {
        var width = Layout.playlistMinWidth
        if showsSelector { width += Layout.playlistSelectorMinWidth + Layout.dividerLineWidth }
        if showsBlock { width += Layout.nowPlayingMinWidth + Layout.dividerLineWidth }
        return width
    }

    /// Allowed selector width for the given area: its own limits, and at most what leaves the playlist (and the
    /// block, if it is shown) their minimum. The selector is fitted first, the block takes what is left.
    private func selectorWidthRange(in size: CGSize, withBlock: Bool) -> ClosedRange<CGFloat> {
        let lower = Layout.playlistSelectorMinWidth
        var room = size.width - Layout.playlistMinWidth - Layout.dividerLineWidth
        if withBlock { room -= Layout.nowPlayingMinWidth + Layout.dividerLineWidth }
        return lower...max(lower, min(Layout.playlistSelectorMaxWidth, room))
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
        if row == nil { finishOpening() }
    }

    /// Shows the playlist (it is the active one, in place and scrolled), a moment later so SwiftUI has drawn the rows
    /// at the new scroll position first. Does nothing while the playlist is still being read.
    private func finishOpening(after delay: Duration = .milliseconds(60)) {
        guard openedName != store.activeName, !store.isLoading else { return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !store.isLoading { openedName = store.activeName }
        }
    }

    /// Starts the queue if it has tracks, else at the first selected row (an album header starts its first track).
    private func playFromSelection() {
        if playback.hasQueuedTracks {
            playback.playPause()
            return
        }
        guard let row = selection.min() else { return }
        playback.play(row: row)
    }

    /// Allowed block width for the given area (what the selector leaves):
    /// - min: album art at its minimum size
    /// - max: whichever is smaller of "leave the playlist its minimum" and, while the album art is shown,
    ///   "album art can't get taller than the block content allows" (art is square, so the
    ///   height limit is also a width limit; widening beyond it would only add empty space).
    ///   Without the art there is no height limit.
    private func blockWidthRange(in size: CGSize) -> ClosedRange<CGFloat> {
        // The block's width is the art's side plus the padding on both sides.
        let maxByHeight = size.height - controlsHeight
        let maxByPlaylist = size.width - Layout.playlistMinWidth - Layout.dividerLineWidth
        let lower = Layout.nowPlayingMinWidth
        var upper = min(maxByPlaylist, Layout.nowPlayingMaxWidth)
        if nowPlaying.layout.isVisible(.albumArt) { upper = min(upper, maxByHeight) }
        return lower...max(lower, upper)
    }
}
