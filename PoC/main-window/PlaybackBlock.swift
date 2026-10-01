import SwiftUI

/// Fake playback state so the UI can be exercised without an audio engine.
@Observable
final class PlaybackState {
    var isPlaying = false
    var position: Double = 83
    var duration: Double = 412
    var volume: Double = 0.7

    let artist = "Boards of Canada"
    let track = "Roygbiv"
    let album = "Music Has the Right to Children"
    let year = "1998"
    let codec = "FLAC · 44.1 kHz · 16 bit · 923 kbps"

    func togglePlay() { isPlaying.toggle() }

    func stop() {
        isPlaying = false
        position = 0
    }

    func tick() {
        guard isPlaying else { return }
        position += 1
        if position >= duration { stop() }
    }
}

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

struct TransportButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct AlbumArtPlaceholder: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [.indigo, .purple, .pink],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 4) {
                    Image(systemName: "music.note")
                        .font(.system(size: geo.size.width * 0.3))
                    Text("\(Int(geo.size.width)) × \(Int(geo.size.height))")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

/// Thin click/drag-to-seek progress bar.
struct SeekBar: View {
    @Binding var value: Double
    let total: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(max(value / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * fraction)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(max(g.location.x / geo.size.width, 0), 1)
                        value = f * total
                    }
            )
        }
        .frame(height: 6)
    }
}
