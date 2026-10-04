import SwiftUI

@main
struct iCanHazMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Directory...") {
                Task { await importer.addDirectory() }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(importer.isBusy)

            Button("Add File(s)...") {
                Task { await importer.addFiles() }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(importer.isBusy)
        }
        CommandMenu("Playlist") {
            Toggle("Don't group by albums", isOn: Binding(
                get: { store.activePlaylist.isFlat },
                set: { flat in Task { await store.setFlat(flat) } }
            ))
            .disabled(importer.isBusy)

            Divider()

            Button("Import playlist...") {
                Task { await importer.importPlaylists() }
            }
            .disabled(importer.isBusy)

            Button("Export playlist...") {
                Task { await PlaylistActions.exportActive() }
            }
            .disabled(importer.isBusy || store.activePlaylist.trackCount == 0)
        }
        CommandMenu("Playback") {
            Toggle("Cursor follows playback", isOn: Bindable(playback).cursorFollowsPlayback)
            Toggle("Playback follows cursor", isOn: Bindable(playback).playbackFollowsCursor)
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
