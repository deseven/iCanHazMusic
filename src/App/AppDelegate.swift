import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched directly (e.g. `build.sh` running the binary from a terminal) instead of
        // via LaunchServices, the app isn't brought to front on its own and its window opens
        // behind the launching app.
        NSApp.activate()
        LastFMService.shared.onConnectionLost = { LastFMActions.connectionLost($0) }
        HotkeyService.shared.start()
        SystemMediaControls.shared.start()
        Log.info("App started, working directory: \(AppPaths.current.workDir.path)")
        Task { await MigrationActions.finishAfterLaunch() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        LastFMService.shared.appDidBecomeActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop the music first (it fades out; being cut off in the middle of the sound pops) and let a playlist
        // write that's still in flight finish.
        let playback = PlaybackState.shared
        guard !playback.isStopped || PlaylistStore.shared.hasPendingWrites else { return .terminateNow }
        Task {
            await playback.stopAndWait()
            await PlaylistStore.shared.flushWrites()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConfigStore.shared.flush()
        Log.info("App terminated")
    }
}
