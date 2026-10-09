// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Right-hand block: album art, playback info, transport buttons, volume.
/// The width is dictated by the parent; the art is a square filling that width.
struct PlaybackBlock: View {
    @Bindable var state: PlaybackState
    /// Starts playback from what is selected in the playlist (the play button while nothing plays).
    let playFromSelection: () -> Void
    /// Whether `playFromSelection` has anything to start.
    let hasSelection: Bool
    /// Reports the height of everything below the art so the parent can compute how big the art may get.
    /// Reported to the parent: minimal height of everything below the art
    /// (info + minimal gap + buttons + volume), excluding the art-to-info gap.
    @Binding var controlsHeight: CGFloat

    private let lyrics = LyricsService.shared

    @State private var infoHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    /// Position the seek bar is being dragged to.
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 0) {
            AlbumArtView(image: state.artwork, isStopped: state.isStopped, isLoading: state.isLoadingArtwork)
                .aspectRatio(1, contentMode: .fit)   // width-driven, always 1:1

            // Info: centered, right below the art
            info
                .padding(.top, Layout.artToControlsGap)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    infoHeight = $0
                    reportHeight()
                }

            // Flexible gap: absorbs leftover height
            Spacer(minLength: Layout.infoToButtonsMinGap)

            // Buttons + volume: pinned to the bottom
            VStack(spacing: 12) {
                transportButtons
                volume
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                bottomHeight = $0
                reportHeight()
            }
        }
        .padding(Layout.blockPadding)
    }

    private func reportHeight() {
        controlsHeight = infoHeight + Layout.infoToButtonsMinGap + bottomHeight
    }

    private var info: some View {
        VStack(spacing: 4) {
            Group {
                Text(line(state.info.map { "\($0.artist) – \($0.title)" }))
                    .font(.headline)
                Text(line(state.info.map { track in
                    track.year.map { "\(track.album) (\($0))" } ?? track.album
                }))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)

            PlaybackProgress(state: state, scrubbing: $scrubbing)

            Text(line(state.info?.codec))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 24)
                .overlay(alignment: .trailing) { lyricsButton }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// Only there for a track that has lyrics; the space stays, so nothing moves when it comes and goes.
    private var lyricsButton: some View {
        let available = lyrics.current != nil
        return Button {
            LyricsSheet.present(.playing)
        } label: {
            Image(systemName: "text.page")
                .font(.system(size: 14))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Lyrics")
        .opacity(available ? 1 : 0)
        .disabled(!available)
        .accessibilityHidden(!available)
    }

    private var transportButtons: some View {
        let stopped = state.isStopped
        return HStack(spacing: 0) {
            TransportButton(symbol: "backward.end.fill", help: "Previous album") { state.previousAlbum() }
                .disabled(stopped)
            Spacer(minLength: 0)
            TransportButton(symbol: "backward.fill", help: "Previous track") { state.previousTrack() }
                .disabled(stopped)
            Spacer(minLength: 0)
            TransportButton(symbol: state.status == .playing ? "pause.fill" : "play.fill",
                            help: state.status == .playing ? "Pause" : "Play", size: 26) {
                if stopped { playFromSelection() } else { state.togglePause() }
            }
            .disabled(stopped && !hasSelection)
            Spacer(minLength: 0)
            TransportButton(symbol: "forward.fill", help: "Next track") { state.nextTrack() }
                .disabled(stopped)
            Spacer(minLength: 0)
            TransportButton(symbol: "forward.end.fill", help: "Next album") { state.nextAlbum() }
                .disabled(stopped)
            Spacer(minLength: 0)
            TransportButton(symbol: "stop.fill", help: "Stop") { state.stop() }
                .disabled(stopped)
        }
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: $state.volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    /// Keeps the line's height when there is nothing to show.
    private func line(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return " " }
        return text
    }
}

/// Time label and seek bar. They read the position themselves, so only this view is re-evaluated when it ticks
/// (reading it in `PlaybackBlock.body` re-evaluates the whole block, which measurably costs CPU).
private struct PlaybackProgress: View {
    let state: PlaybackState
    @Binding var scrubbing: Double?
    private let seekbar = SeekbarSettings.shared

    var body: some View {
        VStack(spacing: 4) {
            Text("\(format(scrubbing ?? state.position)) / \(format(state.duration))")
                .font(.body.monospacedDigit())
                .lineLimit(1)
            switch seekbar.style {
            case .standard:
                SeekBar(value: state.position, total: state.duration, scrubbing: $scrubbing) { state.seek(to: $0) }
            case .waveformRMS, .waveformPeakRMS, .waveformTriBand, .waveformStructure, .spectrogram:
                WaveformSeekBar(style: seekbar.style, value: state.position, total: state.duration,
                                scrubbing: $scrubbing) { state.seek(to: $0) }
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
