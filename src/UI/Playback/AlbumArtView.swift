import SwiftUI

/// The art of the playing album (already a square), or the placeholder while there is none.
struct AlbumArtView: View {
    let image: CGImage?

    var body: some View {
        if let image {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        } else {
            AlbumArtPlaceholder()
        }
    }
}
