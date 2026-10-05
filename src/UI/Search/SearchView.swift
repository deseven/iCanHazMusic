import SwiftUI

/// The content of the search window: the field and under it the results, one line each:
/// `[track] Artist – Title ............ [playlist]`, and at the bottom, always, the legend of the keys.
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
                SearchField(text: $model.query, placeholder: model.placeholder,
                            primary: model.primaryAction, secondary: model.secondaryAction,
                            onMove: { model.move(by: $0) }, onSubmit: { model.choose($0) }, onCancel: onCancel)
            }
            .padding(.horizontal, 16)
            .frame(height: Layout.searchFieldHeight)

            if !model.results.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        SearchRow(result: result, showsKind: model.showsKinds, showsPlaylist: model.showsPlaylists,
                                  isSelected: index == model.selected)
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

            Divider()
            SearchLegend(primary: model.primaryAction, secondary: model.secondaryAction)
                .frame(height: Layout.searchLegendHeight)
        }
        .frame(width: Layout.searchWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.rows) { _, rows in onRowsChange(rows) }
    }
}

/// The keys of the window and what they do.
private struct SearchLegend: View {
    /// What Return does, and what \u{21E7}Return does.
    let primary: SearchAction
    let secondary: SearchAction

    var body: some View {
        HStack(spacing: 18) {
            hint(["\u{238B}"], "cancel")
            hint(["\u{2325}", "\u{21A9}"], "go to item")
            hint(["\u{21E7}", "\u{21A9}"], meaning(of: secondary))
            hint(["\u{21A9}"], meaning(of: primary))
        }
        .frame(maxWidth: .infinity)
    }

    private func meaning(of action: SearchAction) -> String {
        switch action {
        case .play: "play"
        case .goTo: "go to item"
        case .enqueue: "add to queue"
        }
    }

    private func hint(_ keys: [String], _ meaning: String) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { KeyCap(symbol: $0) }
            }
            Text(meaning)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A key of the keyboard: its symbol (as the menus show them) in a small rounded square.
private struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
    }
}

private struct SearchRow: View {
    let result: SearchResult
    /// The tag with the kind of the result (not when everything is a track anyway).
    let showsKind: Bool
    let showsPlaylist: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsKind {
                Tag(text: kindLabel, tint: kindColor, isSelected: isSelected)
                    .frame(width: 62, alignment: .leading)
            }
            Text(result.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if showsPlaylist, result.kind != .playlist {
                WidthCap(maxWidth: 160) {
                    Tag(text: result.playlist, tint: SearchRow.playlistColor, isSelected: isSelected)
                }
            }
        }
        .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
        .padding(.horizontal, 10)
        .frame(height: Layout.searchRowHeight)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    /// The playlist's colour is also the one of the playlist name tag.
    private static let playlistColor = Color(nsColor: .systemPurple)

    private var kindColor: Color {
        switch result.kind {
        case .playlist: SearchRow.playlistColor
        case .album: Color(nsColor: .systemOrange)
        case .track: Color(nsColor: .systemTeal)
        }
    }

    private var kindLabel: String {
        switch result.kind {
        case .playlist: "playlist"
        case .album: "album"
        case .track: "track"
        }
    }
}

/// Gives its one child at most `maxWidth` and is exactly as wide as the child turns out to be. (`.frame(maxWidth:)`
/// would always take that much room, even for a short label, and the title next to it would be cut for nothing.)
private struct WidthCap: SwiftUI.Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A small rounded label, like the ones of the album blocks.
private struct Tag: View {
    let text: String
    let tint: Color
    let isSelected: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : tint)
            .background(isSelected ? Color.white.opacity(0.25) : tint.opacity(0.16), in: Capsule())
    }
}
