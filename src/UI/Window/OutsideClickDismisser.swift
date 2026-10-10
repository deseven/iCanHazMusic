// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// Closes a sheet that merely shows something (lyrics, album art) when the main window behind it is clicked, like
/// dismissing a popover. A sheet blocks its parent, so the click would only beep; the monitor sees it first.
/// Only clicks in the parent's content area count: the title bar still drags the window. Not for sheets that
/// are doing something (the import progress, the update installation) or asking something.
@MainActor
final class OutsideClickDismisser {
    private var monitor: Any?

    init(parent: NSWindow, dismiss: @escaping () -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak parent] event in
            guard let parent, event.window === parent, parent.contentLayoutRect.contains(event.locationInWindow) else {
                return event
            }
            MainActor.assumeIsolated { dismiss() }
            return nil
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
