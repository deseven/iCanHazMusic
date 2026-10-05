// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// The UI side of the updates: the sheet that offers a release, the alerts, and quitting once the installer is
/// waiting for it.
@MainActor
enum UpdateActions {
    private static var isPresenting = false

    /// The manual check (About window): tells the user the result, whatever it is. `window`: where the sheet and the
    /// alerts attach to.
    static func checkManually(on window: NSWindow?) async {
        let service = UpdateService.shared
        guard !service.isChecking else { return }
        do {
            if let update = try await service.check(manual: true) {
                await present(update, on: window)
            } else {
                await Dialogs.showInfo("You have the latest available version of \(AppConstants.appName).",
                                       title: "No Update Available", on: window)
            }
        } catch {
            await Dialogs.showError(error.localizedDescription, title: "Couldn't Check for Updates", on: window)
        }
    }

    /// An automatic check found an update.
    static func updateFound(_ update: UpdateInfo) {
        Task { await present(update, on: nil) }
    }

    private static func present(_ update: UpdateInfo, on preferred: NSWindow?) async {
        guard !isPresenting else { return }
        func freeWindow() -> NSWindow? {
            [preferred, Dialogs.hostWindow, NSApp.keyWindow].compactMap { $0 }
                .first { $0.isVisible && $0.attachedSheet == nil }
        }
        var found = freeWindow()
        if found == nil, MainWindowOpener.shared.isClosed {
            // The app runs without its window ("Close Quits" is off): bring it back to have somewhere to show this.
            await MainWindowOpener.shared.show()
            found = freeWindow()
        }
        guard let window = found else {
            Log.info("updates: no window to show v\(update.version) on, it will be offered again later")
            return
        }
        isPresenting = true
        defer { isPresenting = false }

        let service = UpdateService.shared
        let sheet = UpdateSheet(update: update)
        switch await sheet.run(on: window) {
        case .later:
            await sheet.dismiss()
        case .skip:
            service.skippedVersion = update.version
            await sheet.dismiss()
        case .update:
            sheet.model.progress = "Downloading and checking the update..."
            do {
                try await service.install(update)
                sheet.model.progress = "Restarting..."
                NSApp.terminate(nil)
            } catch {
                Log.error("updates: installing v\(update.version) failed: \(error.localizedDescription)")
                await sheet.dismiss()
                await Dialogs.showError(error.localizedDescription, title: "Update Failed", on: window)
            }
        }
    }
}
