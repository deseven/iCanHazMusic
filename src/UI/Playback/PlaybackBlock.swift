// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Right-hand block: the components chosen in Preferences > Now Playing (album art, what plays, time, seek bar,
/// transport buttons, volume), in the order chosen. They are in two stacks: the top one starts at the top edge, the
/// bottom one is pinned to the bottom edge, and the height left over is between them.
/// The width is dictated by the parent; the art is a square filling that width.
struct PlaybackBlock: View {
    @Bindable var state: PlaybackState
    /// Starts playback from what is selected in the playlist (the play button while nothing plays).
    let playFromSelection: () -> Void
    /// Whether `playFromSelection` has anything to start.
    let hasSelection: Bool
    /// Reported to the parent so it can compute how big the art may get: the least height of the content, the album art
    /// not counted (everything else, and the gaps between the components, the ones next to the art included). The
    /// padding of the block isn't in it.
    @Binding var controlsHeight: CGFloat

    private let lyrics = LyricsService.shared
    private let settings = NowPlayingSettings.shared

    /// What the components measured (the art isn't: its height follows from the width).
    @State private var heights: [NowPlayingComponent: CGFloat] = [:]
    /// Position the seek bar is being dragged to.
    @State private var scrubbing: Double?

    var body: some View {
        let top = settings.layout.visibleTop
        let bottom = settings.layout.visibleBottom
        VStack(spacing: 0) {
            stack(top)
            // Flexible gap: absorbs leftover height
            Spacer(minLength: top.isEmpty || bottom.isEmpty ? 0 : Layout.stacksMinGap)
            stack(bottom)
        }
        .padding(Layout.blockPadding)
        .onChange(of: requiredHeight(top: top, bottom: bottom), initial: true) { _, height in
            controlsHeight = height
        }
    }

    private func requiredHeight(top: [NowPlayingComponent], bottom: [NowPlayingComponent]) -> CGFloat {
        func stackHeight(_ components: [NowPlayingComponent]) -> CGFloat {
            var total: CGFloat = 0
            for (index, component) in components.enumerated() {
                total += heights[component] ?? 0
                if index > 0 { total += Layout.componentGap(components[index - 1], component) }
            }
            return total
        }
        let gap = top.isEmpty || bottom.isEmpty ? 0 : Layout.stacksMinGap
        return stackHeight(top) + gap + stackHeight(bottom)
    }

    private func stack(_ components: [NowPlayingComponent]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(components.enumerated()), id: \.element) { index, component in
                view(for: component)
                    .padding(.top, index == 0 ? 0 : Layout.componentGap(components[index - 1], component))
            }
        }
    }

    @ViewBuilder
    private func view(for component: NowPlayingComponent) -> some View {
        switch component {
        case .albumArt:
            AlbumArtView(image: state.artwork, isStopped: state.isStopped, isLoading: state.isLoadingArtwork)
                .aspectRatio(1, contentMode: .fit)   // width-driven, always 1:1
        case .title:
            measured(component) {
                Text(line(state.info.map { TextTemplate.render(settings.titleTemplate, values: $0.templateValues) }))
                    .font(Self.scaled(.headline, weight: .bold, percent: settings.titleScale))
                    .centeredLine()
            }
        case .subtitle:
            measured(component) {
                Text(line(state.info.map { TextTemplate.render(settings.subtitleTemplate, values: $0.templateValues) }))
                    .font(Self.scaled(.body, weight: .regular, percent: settings.subtitleScale))
                    .foregroundStyle(.secondary)
                    .centeredLine()
            }
        case .duration:
            measured(component) { PlaybackTime(state: state, scrubbing: $scrubbing) }
        case .seekbar:
            measured(component) { PlaybackSeekbar(state: state, scrubbing: $scrubbing) }
        case .details:
            measured(component) {
                Text(line(state.info?.codec))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .centeredLine()
                    .padding(.horizontal, 24)
                    .overlay(alignment: .trailing) { lyricsButton }
            }
        case .controls:
            measured(component) { transportButtons }
        case .volume:
            measured(component) { volume }
        }
    }

    /// `style` with its size scaled by `percent`; the weight stays the style's own (`weight` is what `style` has).
    private static func scaled(_ style: Font.TextStyle, weight: Font.Weight, percent: Int) -> Font {
        guard percent != ConfigLimits.componentTextScaleDefault else { return .system(style, weight: weight) }
        let base = NSFont.preferredFont(forTextStyle: style == .headline ? .headline : .body).pointSize
        return .system(size: base * CGFloat(percent) / 100, weight: weight)
    }

    private func measured<Content: View>(_ component: NowPlayingComponent,
                                         @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[component] = $0 }
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

    /// The buttons chosen in the options of the component, spread over the width of the block.
    private var transportButtons: some View {
        let buttons = settings.controls.visible
        return HStack(spacing: 0) {
            ForEach(Array(buttons.enumerated()), id: \.element) { index, control in
                if index > 0 { Spacer(minLength: 0) }
                transportButton(control)
            }
        }
        .frame(minHeight: TransportButton.side)
    }

    @ViewBuilder
    private func transportButton(_ control: PlaybackControl) -> some View {
        let stopped = state.isStopped
        switch control {
        case .previousAlbum:
            TransportButton(symbol: "backward.end.fill", help: "Previous album") { state.previousAlbum() }
                .disabled(stopped)
        case .previousTrack:
            TransportButton(symbol: "backward.fill", help: "Previous track") { state.previousTrack() }
                .disabled(stopped)
        case .playPause:
            TransportButton(symbol: state.status == .playing ? "pause.fill" : "play.fill",
                            help: state.status == .playing ? "Pause" : "Play", size: 26) {
                if stopped { playFromSelection() } else { state.togglePause() }
            }
            .disabled(stopped && !hasSelection)
        case .nextTrack:
            TransportButton(symbol: "forward.fill", help: "Next track") { state.nextTrack() }
                .disabled(stopped)
        case .nextAlbum:
            TransportButton(symbol: "forward.end.fill", help: "Next album") { state.nextAlbum() }
                .disabled(stopped)
        case .stop:
            TransportButton(symbol: "stop.fill", help: "Stop") { state.stop() }
                .disabled(stopped)
        case .randomTrack:
            TransportButton(symbol: "die.face.5.fill", help: "Play a random track") { state.randomTrack() }
        case .randomAlbum:
            TransportButton(symbol: "square.stack.fill", help: "Play a random album") { state.randomAlbum() }
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

private extension View {
    /// One line, centered across the block's width, cut off at the end if it doesn't fit.
    func centeredLine() -> some View {
        lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// The time label. It must not read the position here: the label follows it by itself (see `TimeLabel`), so the
/// once-a-second changes don't touch SwiftUI at all (they measurably cost CPU there).
private struct PlaybackTime: View {
    let state: PlaybackState
    @Binding var scrubbing: Double?

    var body: some View {
        TimeLabel(state: state, scrubbing: scrubbing)
            .frame(maxWidth: .infinity)
    }
}

/// The seek bar, in the style chosen in Preferences. It reads `anchor`, not `position`: that doesn't change while a
/// track plays, and the bar moves by itself (see `SeekBar`).
private struct PlaybackSeekbar: View {
    let state: PlaybackState
    @Binding var scrubbing: Double?
    private let seekbar = NowPlayingSettings.shared

    var body: some View {
        switch seekbar.style {
        case .standard:
            SeekBar(anchor: state.anchor, total: state.duration, scrubbing: $scrubbing) { state.seek(to: $0) }
        case .waveformRMS, .waveformPeakRMS, .waveformTriBand, .waveformStructure, .spectrogram:
            WaveformSeekBar(style: seekbar.style, anchor: state.anchor, total: state.duration,
                            scrubbing: $scrubbing) { state.seek(to: $0) }
        }
    }
}
