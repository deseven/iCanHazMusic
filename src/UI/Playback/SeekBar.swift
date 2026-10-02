import SwiftUI

/// Thin click/drag-to-seek progress bar. While dragging it only previews (`scrubbing`); the seek itself
/// happens once, when the mouse is released.
struct SeekBar: View {
    let value: Double
    let total: Double
    /// The position being dragged to, nil when not dragging.
    @Binding var scrubbing: Double?
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let shown = scrubbing ?? value
            let fraction = total > 0 ? min(max(shown / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * fraction)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard total > 0 else { return }
                        scrubbing = target(for: g.location.x, width: geo.size.width)
                    }
                    .onEnded { g in
                        defer { scrubbing = nil }
                        guard total > 0 else { return }
                        onSeek(target(for: g.location.x, width: geo.size.width))
                    }
            )
        }
        .frame(height: 6)
    }

    private func target(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * total
    }
}
