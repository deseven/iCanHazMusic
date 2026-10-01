import SwiftUI

/// [ playlist selector (toggle) ] [ playlist ] [ divider ] [ playback block ]
struct MainWindow: View {
    @State private var columnVisibility: NavigationSplitViewVisibility
    /// Sidebar width at launch. Kept constant: it's only the *ideal* width the column starts with.
    @State private var initialSidebarWidth: CGFloat

    init() {
        let selector = ConfigStore.shared.config.ui.playlistSelector
        _columnVisibility = State(initialValue: selector.shown ? .all : .detailOnly)
        _initialSidebarWidth = State(initialValue: CGFloat(selector.width))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PlaylistSelector()
                .navigationSplitViewColumnWidth(min: Layout.sidebarMin,
                                                ideal: initialSidebarWidth,
                                                max: Layout.sidebarMax)
                .sidebarMaxWidth(Layout.sidebarMax)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in

                    // Ignore the intermediate widths while the sidebar animates in/out.
                    guard (Layout.sidebarMin...Layout.sidebarMax).contains(width) else { return }
                    ConfigStore.shared.update { $0.ui.playlistSelector.width = Int(width.rounded()) }
                }
        } detail: {
            PlayerArea()
        }
        .dropDestination(for: URL.self) { urls, _ in
            ImportCoordinator.shared.handleDrop(urls)
        }
        .navigationTitle(AppConstants.appName)
        .onChange(of: columnVisibility) { _, visibility in
            ConfigStore.shared.update { $0.ui.playlistSelector.shown = (visibility != .detailOnly) }
        }
    }
}
