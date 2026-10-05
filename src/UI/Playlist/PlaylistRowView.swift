import SwiftUI

/// What a row of the queue shows besides the track.
struct QueuedRow {
    /// Its place in the queue, from 1.
    let number: Int
    /// The playlist of the track, if that is to be said.
    let playlist: String?
}

/// One row of the flattened playlist: an album header or a track. `queued`: it is a row of the queue view, which
/// has its own kind of track row; `queuePosition`: the track is queued (shown where the play symbol goes).
struct PlaylistRowView: View {
    let playlist: Playlist
    let index: Int
    let isSelected: Bool
    let isPlaying: Bool
    let showAlbumArt: Bool
    var queuePosition: Int?
    var queued: QueuedRow?

    var body: some View {
        let row = playlist.rows[index]
        if let track = playlist.track(for: row), let queued {
            QueueRowContent(track: track, row: queued, isSelected: isSelected)
                .frame(height: Layout.trackRowHeight)
                .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        } else if let track = playlist.track(for: row) {
            TrackRowContent(track: track, album: playlist.albums[row.albumIndex].title,
                            showArtist: playlist.isFlat || playlist.albums[row.albumIndex].hasMultipleArtists,
                            showNumber: !playlist.isFlat, isPlaying: isPlaying, queuePosition: queuePosition,
                            isSelected: isSelected)
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
                HStack(spacing: 6) {
                    if let year = album.year {
                        AlbumTag(text: year, color: tagColor(.secondary))
                    }
                    AlbumTag(text: album.trackCountText, color: tagColor(.teal))
                    if let total = album.totalDuration {
                        AlbumTag(text: NotificationService.formatDuration(total), color: tagColor(.orange))
                    }
                }
                .padding(.top, 3)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tags turn white together with the rest of the row when that is selected.
    private func tagColor(_ color: Color) -> Color {
        isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : color
    }
}

/// One of the small rounded labels of the album block's third line, built like the source tag of the lyrics sheet.
private struct AlbumTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
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
    let queuePosition: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            // The placeholder keeps the column's width in every row; an empty `Group` would collapse.
            // The playing track is never queued, so the two never compete for the place.
            Color.clear
                .frame(width: Layout.trackStatusColumnWidth)
                .overlay {
                    if isPlaying {
                        Image(systemName: "play.fill").font(.system(size: 9))
                    } else if let queuePosition {
                        QueueBadge(position: queuePosition, isSelected: isSelected)
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

/// The place of a queued track in the queue (1...99, `Q` beyond that), a small label in the status column.
private struct QueueBadge: View {
    let position: Int
    let isSelected: Bool

    var body: some View {
        Text(position > 99 ? "Q" : "\(position)")
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.accentColor)
            .padding(.horizontal, 4)
            .frame(minWidth: 16)
            .background(isSelected ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.16), in: Capsule())
            .help(position > 99 ? "Queued (\(position))" : "Queued")
    }
}

/// A track of the queue view: `place  Artist – Title  duration  [playlist]`.
private struct QueueRowContent: View {
    let track: Track
    let row: QueuedRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text("\(row.number)")
                .monospacedDigit()
                .opacity(0.65)
                .frame(width: 44, alignment: .trailing)
            Text("\(track.artist) – \(track.title)")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
            Text(track.durationText)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
            if let playlist = row.playlist {
                WidthCap(maxWidth: 160) {
                    Tag(text: playlist, tint: .playlistLabel, isSelected: isSelected)
                }
                .padding(.leading, 12)
            }
            Color.clear.frame(width: 10, height: 1)
        }
        .font(.system(size: 12))
    }
}
