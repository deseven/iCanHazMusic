import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched directly (e.g. `build.sh` running the binary from a terminal) instead of
        // via LaunchServices, the app isn't brought to front on its own and its window opens
        // behind the launching app.
        NSApp.activate()
        LastFMService.shared.onConnectionLost = { LastFMActions.connectionLost($0) }
        Log.info("App started, working directory: \(AppPaths.current.workDir.path)")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        LastFMService.shared.appDidBecomeActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Let a playlist write that's still in flight finish first.
        guard PlaylistStore.shared.hasPendingWrites else { return .terminateNow }
        Task {
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
