import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched directly (e.g. `build.sh` running the binary from a terminal) instead of
        // via LaunchServices, the app isn't brought to front on its own and its window opens
        // behind the launching app.
        NSApp.activate()
        Log.info("App started, working directory: \(AppPaths.workDir.path)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConfigStore.shared.flush()
        Log.info("App terminated")
    }
}
