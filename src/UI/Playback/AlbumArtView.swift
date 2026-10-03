import SwiftUI

/// The art of the playing album (already a square). Without an image the square is black: a spinner while the art
/// is being looked up, `[ playback stopped ]` while nothing plays, `[ no album art ]` if the album has none.
struct AlbumArtView: View {
    let image: CGImage?
    let isStopped: Bool
    let isLoading: Bool

    var body: some View {
        Color.black
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    @ViewBuilder
    private var content: some View {
        if isStopped {
            caption("[ playback stopped ]")
        } else if isLoading {
            ProgressView()
                .controlSize(.small)
                .environment(\.colorScheme, .dark)
        } else if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            caption("[ no album art ]")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(8)
    }
}
