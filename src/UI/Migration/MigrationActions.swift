// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// The UI side of `LegacyMigration`: asks at launch, before anything touches the working directory, whether the data
/// of the previous version should be taken over, and finishes the job once the main window is up.
@MainActor
enum MigrationActions {
    private enum Pending {
        case startFromScratch
        case migrate(LegacyMigration.Plan)
    }

    private static var pending: Pending?

    /// Call first thing at launch, before any of the singletons (`ConfigStore.shared`, `PlaylistStore.shared`...) is
    /// used. If the working directory holds the data of the previous version and no `config.json`, asks what to
    /// do. "No" quits the app. Otherwise the app goes on with its usual fresh start (that's what creates the config
    /// and the `main` playlist) and `finishAfterLaunch()` does the rest.
    static func askAtLaunch() {
        let paths = AppPaths.current
        guard LegacyMigration.isNeeded(paths: paths) else { return }
        Log.info("data of the previous version found in \(paths.workDir.path)")

        // `NSApp` doesn't exist yet this early.
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Migrate from the previous version?"
        alert.informativeText = """
            Data of the previous version of iCanHazMusic was found. "Yes" takes over its settings and \
            playlist, "Start from scratch" starts with the defaults. Either way everything else the previous \
            version has left in \(paths.workDir.path) is deleted, and that can't be undone.

            "No" quits the app and leaves everything as it is.
            """
        // The first button is the rightmost one: No / Start from scratch / Yes.
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "Start from scratch")
        let no = alert.addButton(withTitle: "No")
        no.keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let plan = LegacyMigration.loadPlan(paths: paths)
            // The first use creates the config with the defaults, the old settings go on top of it. This happens
            // now, before the other singletons read their settings from it.
            let screenHeight = NSScreen.screens.first.map { Int($0.frame.height) }
            ConfigStore.shared.update { plan.settings?.apply(to: &$0, screenHeight: screenHeight) }
            ConfigStore.shared.flush()
            pending = .migrate(plan)
        case .alertSecondButtonReturn:
            pending = .startFromScratch
        default:
            Log.info("migration declined, quitting")
            exit(0)
        }
    }

    /// Call once the app has launched. Reads the old playlist into `main`, then removes what is left of the previous
    /// version. Does nothing if `askAtLaunch()` didn't find anything to migrate.
    static func finishAfterLaunch() async {
        guard let pending else { return }
        self.pending = nil

        let store = PlaylistStore.shared
        var note: String?
        if case .migrate(let plan) = pending {
            note = await importTracks(of: plan, into: store)
        }
        await store.flushWrites()
        ConfigStore.shared.flush()
        LegacyMigration.cleanUp(paths: .current)

        if let note {
            await Dialogs.showInfo(note, title: "Migration Finished")
        }
    }

    /// Returns what the user should be told, if anything.
    private static func importTracks(of plan: LegacyMigration.Plan, into store: PlaylistStore) async -> String? {
        guard !plan.files.isEmpty else { return nil }

        // The import needs the window to put its progress sheet on and the playlist loaded.
        while Dialogs.hostWindow?.isVisible != true || ImportCoordinator.shared.isBusy {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(300))   // let the window settle

        if plan.settings?.dontGroupByAlbums == true {
            await store.setFlat(true)
        }
        guard let result = await ImportCoordinator.shared.importList(plan.files) else {
            Log.info("migration: playlist import didn't complete")
            return nil
        }
        Log.info("migration: \(result.total - result.failed) of \(result.total) tracks imported")
        guard result.failed > 0 else { return nil }
        return "\(result.failed) of \(result.total) tracks of the previous playlist couldn't be found or read and were left out."
    }
}
