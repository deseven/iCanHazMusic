// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

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
    let style: TrackRowStyle
    var queuePosition: Int?
    var queued: QueuedRow?

    var body: some View {
        let row = playlist.rows[index]
        if let track = playlist.track(for: row), let queued {
            QueueRowContent(track: track, row: queued, isSelected: isSelected, style: style)
                .frame(height: style.rowHeight)
                .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        } else if let track = playlist.track(for: row) {
            TrackRowContent(track: track, album: playlist.albums[row.albumIndex].title,
                            showArtist: playlist.isFlat || playlist.albums[row.albumIndex].hasMultipleArtists,
                            columns: style.columns(isFlat: playlist.isFlat), style: style, isPlaying: isPlaying,
                            queuePosition: queuePosition, isSelected: isSelected)
                .frame(height: style.rowHeight)
                .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        } else {
            AlbumHeaderContent(album: playlist.albums[row.albumIndex], isSelected: isSelected,
                               style: style.headerStyle)
                .frame(height: PlaylistLayout.headerHeight(showAlbumArt: style.showsAlbumArt))
                .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.primary.opacity(0.06))
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        }
    }
}

private struct AlbumHeaderContent: View {
    let album: Album
    let isSelected: Bool
    /// Without the album art no cover is loaded either.
    let style: AlbumHeaderStyle

    var body: some View {
        HStack(spacing: 10) {
            switch style {
            case .albumArt:
                cover
                info(alignment: .leading)
                Spacer(minLength: 0)
            case .albumArtRight:
                Spacer(minLength: 0)
                info(alignment: .trailing)
                cover
            case .noAlbumArt:
                singleLine
            }
        }
        .padding(.horizontal, Layout.trackRowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `Artist          Album [tags]`: both texts are cut short when the room runs out, the tags never are.
    private var singleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(album.artist)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 12)
            if !album.title.isEmpty {
                Text(album.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            tags.fixedSize()
                .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + Layout.albumTagBaselineLift }
        }
    }

    private var cover: some View {
        Image(nsImage: CoverCache.image(for: album))
            .resizable()
            .frame(width: Layout.coverSize, height: Layout.coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The three lines: artist, album, tags.
    private func info(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(album.artist).font(.system(size: 13, weight: .bold))
            Text(album.title).font(.system(size: 12))
            tags.padding(.top, 3)
        }
        .lineLimit(1)
    }

    /// The year, the track count and the total duration.
    private var tags: some View {
        HStack(spacing: 6) {
            if let year = album.year {
                AlbumTag(text: year, color: tagColor(.secondary))
            }
            AlbumTag(text: album.trackCountText, color: tagColor(.teal))
            if let total = album.totalDuration {
                AlbumTag(text: NotificationService.formatDuration(total), color: tagColor(.orange))
            }
        }
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

/// A track: the visible `columns` in their order, the title taking the room the others leave (without a title the
/// columns line up on the left).
private struct TrackRowContent: View {
    let track: Track
    /// Album title as the lyrics are keyed by it.
    let album: String
    /// Compilation albums and flat playlists: "artist – title" instead of just the title.
    let showArtist: Bool
    let columns: [PlaylistColumn]
    let style: TrackRowStyle
    let isPlaying: Bool
    let queuePosition: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: style.scaled(Layout.trackColumnGap)) {
            ForEach(columns) { column in
                cell(column)
            }
            if !columns.contains(.title) { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Layout.trackRowPadding)
        .font(.system(size: style.fontSize))
    }

    @ViewBuilder
    private func cell(_ column: PlaylistColumn) -> some View {
        switch column {
        case .status:
            // The placeholder keeps the column's width in every row; an empty `Group` would collapse.
            // The playing track is never queued, so the two never compete for the place.
            Color.clear
                .frame(width: style.scaled(Layout.trackStatusColumnWidth))
                .overlay(alignment: .trailing) {
                    if isPlaying {
                        Image(systemName: "play.fill").font(.system(size: style.scaled(Layout.trackPlaySymbolSize)))
                    } else if let queuePosition {
                        QueueBadge(position: queuePosition, isSelected: isSelected, scale: style.scale)
                    }
                }
        case .number:
            Text(track.numberText)
                .monospacedDigit()
                .opacity(0.65)
                .frame(width: style.scaled(Layout.trackNumberColumnWidth), alignment: .trailing)
        case .title:
            Text(showArtist ? "\(track.artist) – \(track.title)" : track.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .duration:
            Text(track.durationText)
                .monospacedDigit()
                .frame(width: style.durationWidth, alignment: .trailing)
        case .details:
            HStack(spacing: 0) {
                // The placeholder keeps the place of the symbol in every row, so the codecs line up.
                Color.clear
                    .frame(width: style.scaled(Layout.trackLyricsWidth))
                    .overlay { lyricsButton }
                Text(track.codec)
                    .lineLimit(1)
                    .opacity(0.65)
                    .frame(width: style.scaled(Layout.trackCodecWidth), alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var lyricsButton: some View {
        if LyricsService.shared.hasLyrics(artist: track.artist, title: track.title, album: album) {
            Button {
                LyricsSheet.present(.track(artist: track.artist, title: track.title, album: album))
            } label: {
                Image(systemName: "text.page")
                    .font(.system(size: style.scaled(Layout.trackLyricsSymbolSize)))
                    .frame(width: style.scaled(Layout.trackLyricsWidth), height: style.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show lyrics")
        }
    }
}

/// The place of a queued track in the queue (1...99, `Q` beyond that), a small label in the status column.
private struct QueueBadge: View {
    let position: Int
    let isSelected: Bool
    let scale: CGFloat

    var body: some View {
        Text(position > 99 ? "Q" : "\(position)")
            .font(.system(size: 9 * scale, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.accentColor)
            .padding(.horizontal, 4 * scale)
            .frame(minWidth: 16 * scale)
            .background(isSelected ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.16), in: Capsule())
            .help(position > 99 ? "Queued (\(position))" : "Queued")
    }
}

/// A track of the queue view: `place  Artist – Title  duration  [playlist]`.
private struct QueueRowContent: View {
    let track: Track
    let row: QueuedRow
    let isSelected: Bool
    /// Only its size is used: the queue has its own columns.
    let style: TrackRowStyle

    var body: some View {
        HStack(spacing: 0) {
            Text("\(row.number)")
                .monospacedDigit()
                .opacity(0.65)
                .frame(width: style.scaled(Layout.queueNumberColumnWidth), alignment: .trailing)
            Text("\(track.artist) – \(track.title)")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, style.scaled(12))
            Text(track.durationText)
                .monospacedDigit()
                .frame(width: style.durationWidth, alignment: .trailing)
                .padding(.leading, style.scaled(12))
            if let playlist = row.playlist {
                WidthCap(maxWidth: 160) {
                    Tag(text: playlist, tint: .playlistLabel, isSelected: isSelected)
                }
                .padding(.leading, 12)
            }
            Color.clear.frame(width: 10, height: 1)
        }
        .font(.system(size: style.fontSize))
    }
}
