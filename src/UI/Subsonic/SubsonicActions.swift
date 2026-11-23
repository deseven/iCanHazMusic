// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// File > Add from Subsonic...: the sheet to pick tracks in, and what is done with the pick (`ImportCoordinator.addSubsonic`:
/// covers, then adding to the playlist on the server, behind the progress sheet; the songs are downloaded when they play,
/// or right away for a playlist that is downloaded automatically). The tracks go to the active
/// playlist, which has to be one of a server: that is the connection they are taken from.
@MainActor
enum SubsonicActions {
    private static var isPresenting = false

    /// What a sheet is shown in and what it handed back.
    private final class SheetResult<Outcome> {
        var sheet: NSWindow?
        var outcome: Outcome?
    }

    /// Whether "Add from Subsonic..." can be used now: the shown playlist is one of a server and can be changed.
    static var canAdd: Bool {
        let store = PlaylistStore.shared
        return store.activeID.isRemote && store.canEdit(store.activeID)
    }

    /// Shows the sheet on the main window and adds the tracks that were picked to the active playlist (on its server).
    static func addFromSubsonic() async {
        let store = PlaylistStore.shared
        let service = SubsonicService.shared
        let playlist = store.activeID
        guard case .remote(let connectionID, _) = playlist, store.canEdit(playlist) else { return }
        guard let window = await sheetWindow(service) else { return }

        let model = SubsonicBrowseModel(service: service, connection: connectionID)
        let playlistName = store.displayName(of: playlist)
        let connectionName = service.displayName(of: connectionID)
        let outcome: SubsonicBrowseOutcome? = await present(on: window) { finish in
            SubsonicBrowseSheet(model: model, playlistName: playlistName, connectionName: connectionName, finish: finish)
        }
        guard let outcome, !outcome.picks.isEmpty else { return }
        guard let connection = service.connection(connectionID), store.canEdit(playlist) else {
            await Dialogs.showError("The connection was switched off or the playlist can't be changed any more.",
                                    title: "Nothing Added")
            return
        }

        let picks = outcome.picks
        await ImportCoordinator.shared.addSubsonic(from: connection, to: playlist) {
            SubsonicImport.albums(of: picks, connection: connectionID)
        }
    }

    /// Something the user did to a playlist of a server couldn't be carried there.
    static func playlistProblem(title: String, message: String) {
        Task { await Dialogs.showError(message, title: title) }
    }

    // MARK: - Sheets

    /// The main window to show a sheet on, nil if one can't be shown now.
    private static func sheetWindow(_ service: SubsonicService) async -> NSWindow? {
        let importer = ImportCoordinator.shared
        guard !isPresenting, !importer.isBusy, service.hasEnabledConnections,
              let window = await MainWindowOpener.shared.show(), window.attachedSheet == nil, !importer.isBusy else { return nil }
        return window
    }

    /// Shows `content` as a sheet of `window` and returns what it handed to `finish` (nil if it was cancelled).
    private static func present<Outcome, Content: View>(
        on window: NSWindow,
        content: (@escaping (Outcome?) -> Void) -> Content
    ) async -> Outcome? {
        let result = SheetResult<Outcome>()
        isPresenting = true
        return await withCheckedContinuation { continuation in
            let hosting = NSHostingController(rootView: content { outcome in
                result.outcome = outcome
                if let sheet = result.sheet, let parent = sheet.sheetParent { parent.endSheet(sheet) }
            })
            hosting.sizingOptions = [.preferredContentSize]
            let sheet = NSWindow(contentViewController: hosting)
            sheet.styleMask = [.titled]
            result.sheet = sheet
            window.beginSheet(sheet) { _ in
                isPresenting = false
                result.sheet = nil
                continuation.resume(returning: result.outcome)
            }
        }
    }
}
