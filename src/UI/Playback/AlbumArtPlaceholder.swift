import SwiftUI

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
