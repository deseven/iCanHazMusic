// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The art of the playing album (already a square). Without an image the square is black: a spinner while the art
/// is being looked up, `[ playback stopped ]` while nothing plays, `[ no album art ]` if the album has none.
///
/// With `NowPlayingSettings.zoomAlbumArt` on, the pointer over the art shows it at its original size (one image pixel
/// per screen pixel) like the image zooms of web shops: the point of the art under the pointer stays under it, so
/// moving the pointer from one corner to the other pans over the whole image. It is the original image
/// (`PlaybackArtwork` doesn't shrink it) and nothing is zoomed if the art is shown at nearly that size already
/// (`zoomedSide`).
///
/// Clicking the art opens it at its original size in a sheet (`AlbumArtSheet`), whatever the zoom setting is.
struct AlbumArtView: View {
    let image: CGImage?
    let isStopped: Bool
    let isLoading: Bool

    private let settings = NowPlayingSettings.shared
    @Environment(\.displayScale) private var displayScale
    /// Side of the shown square.
    @State private var side: CGFloat = 0
    /// Where the pointer is, as a fraction (0...1) of the width/height; nil while it is outside.
    @State private var pointer: CGPoint?

    var body: some View {
        Color.black
            .aspectRatio(1, contentMode: .fit)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { side = $0 }
            .overlay { content }
            .overlay { zoomed }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isStopped, !isLoading, let image else { return }
                AlbumArtSheet.present(image)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard side > 0 else { return }
                    pointer = CGPoint(x: min(max(location.x / side, 0), 1), y: min(max(location.y / side, 0), 1))
                case .ended:
                    pointer = nil
                }
            }
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

    /// The art at its original size, covering the normal one. The image is laid out that big, with its top left
    /// corner moved so that the point under the pointer stays where it is (the overflow is clipped).
    @ViewBuilder
    private var zoomed: some View {
        if settings.zoomAlbumArt, !isStopped, !isLoading, let image, let pointer,
           let big = Self.zoomedSide(imagePixels: min(image.width, image.height), shownSide: side, scale: displayScale) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: big, height: big)
                .offset(x: -pointer.x * (big - side), y: -pointer.y * (big - side))
                .frame(width: side, height: side, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }

    /// The side, in points, of the image at its original size (one image pixel per screen pixel of `scale`), or nil if
    /// there is nothing to zoom: the art is shown at `Layout.albumArtNoZoomRatio` of that size or more (it would be
    /// less than 10% smaller).
    static func zoomedSide(imagePixels: Int, shownSide: CGFloat, scale: CGFloat) -> CGFloat? {
        guard imagePixels > 0, shownSide > 0, scale > 0 else { return nil }
        guard shownSide * scale < CGFloat(imagePixels) * Layout.albumArtNoZoomRatio else { return nil }
        return CGFloat(imagePixels) / scale
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
