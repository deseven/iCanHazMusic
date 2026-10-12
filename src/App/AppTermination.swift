// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// The one way the app quits itself: don't call `terminate` anywhere else.
///
/// `NSApplication.terminate` must not be called from async main-actor code (a `Task`): while something plays,
/// `AppDelegate.applicationShouldTerminate` answers `.terminateLater` and replies from a `Task`. AppKit waits for that
/// reply in a nested run loop inside the main-queue job that called `terminate`, which never lets the main queue run
/// the reply: the app hangs. Started from the run loop, the main queue is free.
///
/// `terminate` is also silently ignored while a sheet is attached to a window: dismiss sheets before calling this.
@MainActor
enum AppTermination {
    static func request(reason: String) {
        Log.info("quitting: \(reason)")
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}
