// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The main window: `PlayerArea` (the playlist between the playlist selector and the now playing block), and a toolbar
/// button for each of the side panels, on the side of the window the panel is on.
struct MainWindow: View {
    private let store = PlaylistStore.shared
    private let nowPlaying = NowPlayingSettings.shared
    private let windowSettings = WindowSettings.shared
    @Environment(\.openWindow) private var openWindow

    /// The app name, followed by the active playlist's name if there are several playlists to tell apart.
    private var windowTitle: String {
        store.names.count > 1 ? "\(AppConstants.appName) • \(store.activeName)" : AppConstants.appName
    }

    var body: some View {
        PlayerArea()
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if windowSettings.swapsSides { nowPlayingToggle } else { selectorToggle }
                }
                ToolbarItem(placement: .primaryAction) {
                    if windowSettings.swapsSides { selectorToggle } else { nowPlayingToggle }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                ImportCoordinator.shared.handleDrop(urls)
            }
            .navigationTitle(windowTitle)
            .onAppear {
                MainWindowOpener.shared.register { openWindow(id: AppConstants.mainWindowID) }
            }
    }

    private var selectorToggle: some View {
        panelToggle("Playlist Selector", isShown: windowSettings.showsPlaylistSelector,
                    edge: windowSettings.swapsSides ? .trailing : .leading) {
            windowSettings.showsPlaylistSelector.toggle()
        }
    }

    private var nowPlayingToggle: some View {
        panelToggle("Now Playing", isShown: nowPlaying.isShown,
                    edge: windowSettings.swapsSides ? .leading : .trailing) {
            nowPlaying.isShown.toggle()
        }
    }

    private func panelToggle(_ title: String, isShown: Bool, edge: HorizontalEdge,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: edge == .leading ? "sidebar.left" : "sidebar.right")
        }
        .help(isShown ? "Hide \(title)" : "Show \(title)")
    }
}
