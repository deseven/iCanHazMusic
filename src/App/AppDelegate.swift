// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched directly (e.g. `build.sh` running the binary from a terminal) instead of
        // via LaunchServices, the app isn't brought to front on its own and its window opens
        // behind the launching app.
        NSApp.activate()
        if MigrationActions.alertWasShown { openMainWindowAfterEarlyAlert() }
        MainThreadWatchdog.shared.start()
        observeSleep()

        PlaybackState.shared.onGiveUp = { PlaybackActions.gaveUp($0) }
        UpdateService.shared.onUpdateFound = { UpdateActions.updateFound($0) }
        UpdateService.shared.start()
        HotkeyService.shared.onSearch = { SearchPanel.shared.toggle() }
        HotkeyService.shared.start()
        SystemMediaControls.shared.start()
        observeWindowFocus()
        Log.info("App started, working directory: \(AppPaths.current.workDir.path)")
        Task {
            // One after the other: the notice is a modal alert, the migration puts a progress sheet on the window.
            await LastFMRemovalNotice.showIfNeeded()
            await MigrationActions.finishAfterLaunch()
        }
        Task { await PlaybackState.shared.restorePlayback() }
    }

    /// SwiftUI doesn't open the main window of an app that showed a modal alert before it launched (the migration
    /// prompt): the user would have to click the Dock icon. That click is a "reopen" request answered by opening the
    /// default window, so send exactly that: opening the app's own bundle makes LaunchServices deliver the reopen
    /// event to the running app. (Calling the delegate method directly doesn't do it, SwiftUI isn't listening there.)
    private func openMainWindowAfterEarlyAlert() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        Log.info("window: opening the main window after the alert shown at launch")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }

    /// The playback position is published (once per second) only while one of our windows is on screen; with the
    /// window closed, minimized, hidden or fully covered nothing is redrawn.
    private func observeWindowFocus() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // A closing window still counts as visible while the notification is delivered; look again on the next turn.
                Task { @MainActor in
                    PlaybackState.shared.isWatched = Self.hasVisibleWindow
                }
            }
        }
        PlaybackState.shared.isWatched = Self.hasVisibleWindow
    }

    /// Sleep and wake go into the log: what goes wrong with devices and network shares often starts there.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Log.info("system: going to sleep")
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Log.info("system: woke up")
        }
    }

    /// Windows that can show the now playing block (not the search panel and the like).
    private static var hasVisibleWindow: Bool {
        NSApp.windows.contains {
            $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
    }


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        WindowSettings.shared.closeQuits
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
