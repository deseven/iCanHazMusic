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
        MainThreadWatchdog.shared.start()
        observeSleep()
        LastFMService.shared.onConnectionLost = { LastFMActions.connectionLost($0) }
        PlaybackState.shared.onGiveUp = { PlaybackActions.gaveUp($0) }
        UpdateService.shared.onUpdateFound = { UpdateActions.updateFound($0) }
        UpdateService.shared.start()
        HotkeyService.shared.onSearch = { SearchPanel.shared.toggle() }
        HotkeyService.shared.start()
        SystemMediaControls.shared.start()
        observeWindowFocus()
        Log.info("App started, working directory: \(AppPaths.current.workDir.path)")
        Task { await MigrationActions.finishAfterLaunch() }
        Task { await PlaybackState.shared.restorePlayback() }
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

    func applicationDidBecomeActive(_ notification: Notification) {
        LastFMService.shared.appDidBecomeActive()
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
