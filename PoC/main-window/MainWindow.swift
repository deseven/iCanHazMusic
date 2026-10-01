import SwiftUI

/// All layout constants in one place.
enum Layout {
    static let windowMinWidth: CGFloat = 800
    static let windowMinHeight: CGFloat = 600

    // Sidebar (playlist selector)
    static let sidebarMin: CGFloat = 160
    static let sidebarIdeal: CGFloat = 200
    static let sidebarMax: CGFloat = 260

    // Playlist column
    static let playlistMinWidth: CGFloat = 280

    // Playback block
    static let artMinSize: CGFloat = 250
    static let blockPadding: CGFloat = 16
    static let artToControlsGap: CGFloat = 14
    static let infoToButtonsMinGap: CGFloat = 12
    static var blockMinWidth: CGFloat { artMinSize + 2 * blockPadding }

    // Divider between playlist and playback block
    static let dividerLineWidth: CGFloat = 1
    static let dividerHitWidth: CGFloat = 12
}

struct MainWindow: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedPlaylist: SamplePlaylist.ID? = SamplePlaylist.all.first?.id

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SamplePlaylist.all, selection: $selectedPlaylist) { playlist in
                Label(playlist.name, systemImage: playlist.icon)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: Layout.sidebarMin,
                                            ideal: Layout.sidebarIdeal,
                                            max: Layout.sidebarMax)
        } detail: {
            // [ playlist ] [ draggable divider ] [ playback block ]
            PlayerArea()
        }
        // Sidebar toggle button in the title bar is provided automatically by NavigationSplitView.
        .navigationTitle("iCanHazMusic")
    }
}

/// Playlist + divider + playback block. Owns the width arithmetic of the right-hand block.
struct PlayerArea: View {
    @State private var playback = PlaybackState()

    /// Width the user asked for by dragging the divider. The effective width is this value
    /// clamped to what the current window size allows (so it "comes back" when the window grows).
    @State private var preferredBlockWidth: CGFloat = Layout.blockMinWidth + 40

    /// Height of everything below the album art, measured from the real view.
    @State private var controlsHeight: CGFloat = 200

    var body: some View {
        GeometryReader { geo in
            let range = blockWidthRange(in: geo.size)
            let blockWidth = min(max(preferredBlockWidth, range.lowerBound), range.upperBound)

            HStack(spacing: 0) {
                PlaylistPlaceholder()
                    .frame(minWidth: Layout.playlistMinWidth, maxWidth: .infinity, maxHeight: .infinity)

                SplitDivider(
                    width: Binding(get: { blockWidth }, set: { preferredBlockWidth = $0 }),
                    range: range
                )

                PlaybackBlock(state: playback, controlsHeight: $controlsHeight)
                    .frame(width: blockWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// Allowed block width for the given area:
    /// - min: album art at its minimum size
    /// - max: whichever is smaller of "leave the playlist its minimum" and
    ///   "album art can't get taller than the block content allows" (art is square, so the
    ///   height limit is also a width limit; widening beyond it would only add empty space).
    private func blockWidthRange(in size: CGSize) -> ClosedRange<CGFloat> {
        let pad = Layout.blockPadding
        let maxArtByHeight = size.height - controlsHeight - Layout.artToControlsGap - 2 * pad
        let maxByHeight = maxArtByHeight + 2 * pad
        let maxByPlaylist = size.width - Layout.playlistMinWidth - Layout.dividerLineWidth
        let lower = Layout.blockMinWidth
        let upper = max(lower, min(maxByHeight, maxByPlaylist))
        return lower...upper
    }
}

// MARK: - Placeholders

struct PlaylistPlaceholder: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .textBackgroundColor)
                VStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                    Text("Playlist view placeholder")
                        .font(.headline)
                    Text("\(Int(geo.size.width)) × \(Int(geo.size.height))")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Vertical draggable divider. Visually a 1pt line, with a wider invisible hit area.
/// Dragging left makes the block (on the right) wider.
struct SplitDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var startWidth: CGFloat?

    var body: some View {
        // Layout-wise the divider is only 1pt wide; the (wider) hit area is an overlay that
        // extends over the neighbouring views, and the divider is raised above them.
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: Layout.dividerLineWidth)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: Layout.dividerHitWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start - value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            )
            .zIndex(1)
    }
}

// MARK: - Sample sidebar data

struct SamplePlaylist: Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String

    static let all: [SamplePlaylist] = [
        .init(id: 0, name: "Library", icon: "music.note.house"),
        .init(id: 1, name: "Favorites", icon: "heart"),
        .init(id: 2, name: "Ambient", icon: "music.note.list"),
        .init(id: 3, name: "Jazz", icon: "music.note.list"),
        .init(id: 4, name: "Electronic", icon: "music.note.list"),
        .init(id: 5, name: "Recently added", icon: "clock"),
    ]
}
