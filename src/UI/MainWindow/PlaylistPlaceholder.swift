import SwiftUI

struct PlaylistPlaceholder: View {
    private let store = PlaylistStore.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .textBackgroundColor)
                VStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                    Text(store.activeName)
                        .font(.headline)
                    Text("Playlist view placeholder")
                    Text("\(Int(geo.size.width)) × \(Int(geo.size.height))")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
