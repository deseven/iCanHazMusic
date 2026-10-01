import SwiftUI

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
