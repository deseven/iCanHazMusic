import SwiftUI

/// Restores the main window's size/position from the config on first appearance and
/// writes them back whenever the user moves or resizes the window.
@MainActor
final class WindowPersistence {
    static let shared = WindowPersistence()

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    /// Minimum share of the window that has to be on a screen for a saved position to be accepted.
    private static let minVisibleShare: CGFloat = 0.75

    private init() {}

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        Dialogs.hostWindow = window

        let target = restoreTarget()
        apply(target, to: window)

        // SwiftUI finishes setting the window up (min size, initial placement) after the view
        // lands in it and would override what we've just set, so apply once more on the next
        // run loop turn and only then start tracking user changes.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.apply(target, to: window)
            self.startObserving(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    private func startObserving(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            }
            observers.append(token)
        }
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: - Restore

    private struct Target {
        var frameSize: NSSize
        /// `nil` means "center on screen".
        var origin: NSPoint?
    }

    private func apply(_ target: Target, to window: NSWindow) {
        // By now SwiftUI has set the real minimum size; never go below it.
        let size = NSSize(width: max(target.frameSize.width, window.minSize.width),
                          height: max(target.frameSize.height, window.minSize.height))
        window.setContentSize(window.contentRect(forFrameRect: NSRect(origin: .zero, size: size)).size)
        if let origin = target.origin {
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
    }

    private func restoreTarget() -> Target {
        let saved = ConfigStore.shared.config.ui.window
        let defaults = AppConfig.UI.Window()

        // The config stores the size of the whole window frame (including title bar / toolbar).
        var frameSize = NSSize(width: saved.width, height: saved.height)
        var origin: NSPoint? = saved.hasPosition ? NSPoint(x: saved.x, y: saved.y) : nil

        if !Self.fitsOnAnyScreen(frameSize) {
            Log.info("saved window size \(saved.width)x\(saved.height) doesn't fit the screen, resetting")
            frameSize = NSSize(width: defaults.width, height: defaults.height)
            origin = nil
            ConfigStore.shared.update { $0.ui.window = defaults }
        }

        if let o = origin, !Self.isMostlyVisible(NSRect(origin: o, size: frameSize)) {
            Log.info("saved window position \(saved.x),\(saved.y) is off screen, centering")
            origin = nil
            ConfigStore.shared.update {
                $0.ui.window.x = defaults.x
                $0.ui.window.y = defaults.y
            }
        }

        return Target(frameSize: frameSize, origin: origin)
    }

    private static func fitsOnAnyScreen(_ size: NSSize) -> Bool {
        NSScreen.screens.contains { screen in
            size.width <= screen.visibleFrame.width && size.height <= screen.visibleFrame.height
        }
    }

    private static func isMostlyVisible(_ frame: NSRect) -> Bool {
        let area = frame.width * frame.height
        guard area > 0 else { return false }
        let visibleArea = NSScreen.screens.reduce(CGFloat(0)) { total, screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
        return visibleArea >= area * minVisibleShare
    }

    // MARK: - Save

    private func save() {
        guard let window,
              !window.styleMask.contains(.fullScreen),
              !window.isMiniaturized
        else { return }

        let frame = window.frame
        ConfigStore.shared.update {
            $0.ui.window.width = Int(frame.width.rounded())
            $0.ui.window.height = Int(frame.height.rounded())
            $0.ui.window.x = Int(frame.origin.x.rounded())
            $0.ui.window.y = Int(frame.origin.y.rounded())
        }
    }
}
