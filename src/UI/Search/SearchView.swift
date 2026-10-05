import SwiftUI

/// The content of the search window: the field and under it the results, one line each:
/// `[track] Artist – Title ............ [playlist]`.
struct SearchView: View {
    let model: SearchModel
    let onCancel: () -> Void
    /// The number of lines under the field changed (the window follows).
    let onRowsChange: (Int) -> Void

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                SearchField(text: $model.query, placeholder: "Search tracks, albums and playlists",
                            onMove: { model.move(by: $0) }, onSubmit: { model.choose() }, onCancel: onCancel)
            }
            .padding(.horizontal, 16)
            .frame(height: Layout.searchFieldHeight)

            if !model.results.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        SearchRow(result: result, showsPlaylist: model.showsPlaylists, isSelected: index == model.selected)
                            .onTapGesture { model.choose(index) }
                    }
                }
                .padding(.vertical, Layout.searchListPadding)
            } else if let message = model.message {
                Divider()
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Layout.searchRowHeight)
                    .padding(.vertical, Layout.searchListPadding)
            }
        }
        .frame(width: Layout.searchWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.rows) { _, rows in onRowsChange(rows) }
    }
}

private struct SearchRow: View {
    let result: SearchResult
    let showsPlaylist: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Tag(text: kindLabel, isSelected: isSelected)
                .frame(width: 62, alignment: .leading)
            Text(result.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if showsPlaylist, result.kind != .playlist {
                Tag(text: result.playlist, isSelected: isSelected)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
        }
        .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        .padding(.horizontal, 10)
        .frame(height: Layout.searchRowHeight)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var kindLabel: String {
        switch result.kind {
        case .playlist: "playlist"
        case .album: "album"
        case .track: "track"
        }
    }
}

/// A small rounded label, like the ones of the album blocks.
private struct Tag: View {
    let text: String
    let isSelected: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(isSelected ? Color.white.opacity(0.25) : Color.primary.opacity(0.1), in: Capsule())
    }
}
