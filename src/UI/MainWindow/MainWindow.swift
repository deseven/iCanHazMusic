// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// [ playlist selector (toggle) ] [ playlist ] [ divider ] [ playback block ]
struct MainWindow: View {
    @State private var columnVisibility: NavigationSplitViewVisibility
    /// Sidebar width at launch. Kept constant: it's only the *ideal* width the column starts with.
    @State private var initialSidebarWidth: CGFloat
    private let store = PlaylistStore.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        let selector = ConfigStore.shared.config.ui.playlistSelector
        _columnVisibility = State(initialValue: selector.shown ? .all : .detailOnly)
        _initialSidebarWidth = State(initialValue: CGFloat(selector.width))
    }

    /// The app name, followed by the active playlist's name if there are several playlists to tell apart.
    private var windowTitle: String {
        store.names.count > 1 ? "\(AppConstants.appName) • \(store.activeName)" : AppConstants.appName
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
        .navigationTitle(windowTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: AppConstants.preferencesWindowID)
                } label: {
                    Label("Preferences", systemImage: "gearshape")
                }
                .help("Preferences (⌘,)")
            }
        }

        .onAppear {
            MainWindowOpener.shared.register { openWindow(id: AppConstants.mainWindowID) }
        }
        .onChange(of: columnVisibility) { _, visibility in
            ConfigStore.shared.update { $0.ui.playlistSelector.shown = (visibility != .detailOnly) }
        }
    }
}
