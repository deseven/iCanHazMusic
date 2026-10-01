import SwiftUI

/// Right-hand block: album art, playback info, transport buttons, volume.
/// The width is dictated by the parent; the art is a square filling that width.
struct PlaybackBlock: View {
    @Bindable var state: PlaybackState
    /// Reports the height of everything below the art so the parent can compute how big the art may get.
    /// Reported to the parent: minimal height of everything below the art
    /// (info + minimal gap + buttons + volume), excluding the art-to-info gap.
    @Binding var controlsHeight: CGFloat

    @State private var infoHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            AlbumArtPlaceholder()
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
        .onReceive(ticker) { _ in state.tick() }
    }

    private func reportHeight() {
        controlsHeight = infoHeight + Layout.infoToButtonsMinGap + bottomHeight
    }

    private var info: some View {
        VStack(spacing: 4) {
            Group {
                Text("\(state.artist) – \(state.track)")
                    .font(.headline)
                Text("\(state.album) (\(state.year))")
                    .foregroundStyle(.secondary)
                Text("\(format(state.position)) / \(format(state.duration))")
                    .font(.body.monospacedDigit())
            }
            .lineLimit(1)
            .truncationMode(.tail)

            SeekBar(value: $state.position, total: state.duration)
                .padding(.vertical, 4)

            Text(state.codec)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var transportButtons: some View {
        HStack(spacing: 0) {
            TransportButton(symbol: "backward.end.fill", help: "Previous album") {}
            Spacer(minLength: 0)
            TransportButton(symbol: "backward.fill", help: "Previous track") {}
            Spacer(minLength: 0)
            TransportButton(symbol: state.isPlaying ? "pause.fill" : "play.fill",
                            help: state.isPlaying ? "Pause" : "Play", size: 26) { state.togglePlay() }
            Spacer(minLength: 0)
            TransportButton(symbol: "forward.fill", help: "Next track") {}
            Spacer(minLength: 0)
            TransportButton(symbol: "forward.end.fill", help: "Next album") {}
            Spacer(minLength: 0)
            TransportButton(symbol: "stop.fill", help: "Stop") { state.stop() }
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

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
