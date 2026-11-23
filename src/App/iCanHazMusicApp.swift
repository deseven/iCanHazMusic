// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

@main
struct iCanHazMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Log.startFileLogging(at: AppPaths.current.logURL)
        // Before anything reads the working directory (the config and playlist stores are created lazily).
        MigrationActions.askAtLaunch()
    }

    var body: some Scene {
        // Single main window (the first scene is opened on launch).
        // Size and position are restored from the config by `WindowPersistence`.
        Window(AppConstants.appName, id: AppConstants.mainWindowID) {
            MainWindow()
                .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
                .background(WindowAccessor { WindowPersistence.shared.attach($0) })
        }
        .defaultSize(width: Layout.windowMinWidth, height: Layout.windowMinHeight)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Window("About \(AppConstants.appName)", id: AppConstants.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        Window("Preferences", id: AppConstants.preferencesWindowID) {
            PreferencesView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        .commands {
            AppCommands()
        }
    }
}

/// Replaces the stock "About" item in the app menu with our own window and adds the Preferences item (⌘,),
/// the import items to File, the Playlist menu and the Playback menu.
private struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private let importer = ImportCoordinator.shared
    private let playback = PlaybackState.shared
    private let store = PlaylistStore.shared
    private let subsonic = SubsonicService.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Files are added to the active playlist: one of this Mac (and not the queue view that may be shown in its
            // place). Tracks of a server go to a playlist of that server.
            let showsQueue = store.isQueueShown && playback.queue.isEnabled
            Button("Add Directory...") {
                Task { await importer.addDirectory() }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!importer.canAddFiles)

            Button("Add File(s)...") {
                Task { await importer.addFiles() }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!importer.canAddFiles)

            // Only when there is a server to add from.
            if subsonic.hasEnabledConnections {
                Button("Add from Subsonic...") {
                    Task { await SubsonicActions.addFromSubsonic() }
                }
                .disabled(importer.isBusy || showsQueue || !SubsonicActions.canAdd)
            }
        }
        CommandMenu("Playlist") {
            Button("Search") { SearchPanel.shared.toggle() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(importer.isBusy)

            Divider()

            let showsQueue = store.isQueueShown && playback.queue.isEnabled
            Toggle("Don't group by albums", isOn: Binding(
                get: { store.activePlaylist.isFlat },
                set: { flat in Task { await PlaylistActions.setFlat(flat) } }
            ))
            .disabled(importer.isBusy || showsQueue)

            Divider()

            // Playlist files are for the playlists of this Mac.
            let isRemote = store.activeID.isRemote
            Button("Import playlist...") {
                Task { await importer.importPlaylists() }
            }
            .disabled(importer.isBusy || showsQueue || isRemote)

            Button("Export playlist...") {
                Task { await PlaylistActions.exportActive() }
            }
            .disabled(importer.isBusy || showsQueue || isRemote || store.activePlaylist.trackCount == 0)
        }
        CommandMenu("Playback") {
            // The same commands as the buttons of the now playing block, in the same order.
            let stopped = playback.isStopped
            Button("Previous Album") { playback.previousAlbum() }
                .disabled(stopped)
            Button("Previous Track") { playback.previousTrack() }
                .disabled(stopped)
            Button(playback.status == .playing ? "Pause" : "Play") { playback.playPause() }
                .disabled(!playback.canPlay)
            Button("Next Track") { playback.nextTrack() }
                .disabled(stopped)
            Button("Next Album") { playback.nextAlbum() }
                .disabled(stopped)
            Button("Stop") { playback.stop() }
                .disabled(stopped)

            Divider()

            Menu("Playback order") {
                Picker("Playback order", selection: Bindable(playback).order) {
                    ForEach(PlaybackOrder.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Menu("At playlist end") {
                Picker("At playlist end", selection: Bindable(playback).atPlaylistEnd) {
                    ForEach(PlaylistEnd.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()

            Toggle("Cursor follows playback", isOn: Bindable(playback).cursorFollowsPlayback)
            Toggle("Playback follows cursor", isOn: Bindable(playback).playbackFollowsCursor)

            if playback.queue.isEnabled {
                Divider()

                Toggle("Stop at queue end", isOn: Bindable(playback.queue).stopAtEnd)
                Button("Clear Queue") { playback.clearQueue() }
                    .disabled(playback.queue.isEmpty)
            }
        }
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppConstants.appName)") {
                openWindow(id: AppConstants.aboutWindowID)
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Preferences...") {
                openWindow(id: AppConstants.preferencesWindowID)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
