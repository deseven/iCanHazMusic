import SwiftUI

/// One row of the flattened playlist: an album header or a track.
struct PlaylistRowView: View {
    let playlist: Playlist
    let index: Int
    let isSelected: Bool
    let isPlaying: Bool
    let showAlbumArt: Bool

    var body: some View {
        let row = playlist.rows[index]
        if let track = playlist.track(for: row) {
            TrackRowContent(track: track, album: playlist.albums[row.albumIndex].title,
                            showArtist: playlist.isFlat || playlist.albums[row.albumIndex].hasMultipleArtists,
                            showNumber: !playlist.isFlat, isPlaying: isPlaying)
                .frame(height: Layout.trackRowHeight)
                .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        } else {
            AlbumHeaderContent(album: playlist.albums[row.albumIndex], isSelected: isSelected,
                               showArt: showAlbumArt)
                .frame(height: showAlbumArt ? Layout.albumHeaderRowHeight : Layout.albumHeaderRowHeightWithoutArt)
                .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.primary.opacity(0.06))
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        }
    }
}

private struct AlbumHeaderContent: View {
    let album: Album
    let isSelected: Bool
    /// Off: no cover is shown, and none is loaded.
    let showArt: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showArt {
                Image(nsImage: CoverCache.image(for: album))
                    .resizable()
                    .frame(width: Layout.coverSize, height: Layout.coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(album.artist).font(.system(size: 13, weight: .bold))
                Text(album.title).font(.system(size: 12))
                Text(album.year ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrackRowContent: View {
    let track: Track
    /// Album title as the lyrics are keyed by it.
    let album: String
    /// Compilation albums and flat playlists: "artist – title" instead of just the title.
    let showArtist: Bool
    /// The track number column (flat playlists have none).
    let showNumber: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 0) {
            // The placeholder keeps the column's width in every row; an empty `Group` would collapse.
            Color.clear
                .frame(width: Layout.trackStatusColumnWidth)
                .overlay {
                    if isPlaying {
                        Image(systemName: "play.fill").font(.system(size: 9))
                    }
                }
            if showNumber {
                Text(track.numberText)
                    .monospacedDigit()
                    .opacity(0.65)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(showArtist ? "\(track.artist) – \(track.title)" : track.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
            // The placeholder keeps the column's width in every row.
            Color.clear
                .frame(width: Layout.trackLyricsColumnWidth)
                .overlay {
                    if LyricsService.shared.hasLyrics(artist: track.artist, title: track.title, album: album) {
                        Button {
                            LyricsSheet.present(.track(artist: track.artist, title: track.title, album: album))
                        } label: {
                            Image(systemName: "text.page")
                                .font(.system(size: 11))
                                .frame(width: Layout.trackLyricsColumnWidth, height: Layout.trackRowHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show lyrics")
                    }
                }
            Text(track.durationText)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
            Text(track.codec)
                .opacity(0.65)
                .frame(width: 110, alignment: .leading)
                .padding(.leading, 12)
        }
        .font(.system(size: 12))
    }
}
