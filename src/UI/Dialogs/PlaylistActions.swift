// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import UniformTypeIdentifiers

/// User-facing playlist operations: ask, validate, perform, report errors.
@MainActor
enum PlaylistActions {
    private static var store: PlaylistStore { .shared }

    /// Saves the active playlist as an `.m3u8`, `.m3u` or `.pls` file (the format is picked in the save panel, or
    /// by typing the extension).
    static func exportActive() async {
        let playlist = store.activePlaylist
        guard !store.activeID.isRemote, playlist.trackCount > 0, let window = await MainWindowOpener.shared.show() else { return }

        let panel = NSSavePanel()
        panel.message = "Export the playlist to a file"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        let picker = ExportFormatPicker(panel: panel, name: store.displayName(of: store.activeID))
        panel.accessoryView = picker.view
        guard await panel.beginSheetModal(for: window) == .OK, var url = panel.url else { return }

        // The format of a typed extension wins over the popup; anything else gets the popup's extension.
        let format: PlaylistFormat
        if let typed = PlaylistFormat(fileExtension: url.pathExtension) {
            format = typed
        } else {
            format = picker.format
            url.appendPathExtension(format.fileExtension)
        }

        let export = PlaylistExchange.export(playlist.entries, format: format)
        do {
            try export.data.write(to: url, options: .atomic)
            Log.info("exported \(playlist.trackCount - export.skipped) tracks to \(url.path), \(export.skipped) skipped")
            if export.skipped > 0 {
                let n = export.skipped
                await Dialogs.showInfo("\(n) \(n == 1 ? "entry was" : "entries were") not exported: tracks of CUE sheets and from Subsonic servers can't be written to these formats.",
                                       title: "Export Incomplete")
            }
        } catch {
            Log.error("can't export playlist to \(url.path): \(error.localizedDescription)")
            await Dialogs.showError("The playlist couldn't be saved: \(error.localizedDescription)", title: "Export Failed")
        }
    }

    /// Makes a new playlist: on this Mac (`connection` nil) or on a Subsonic server.
    static func create(on connection: UUID? = nil) async {
        let service = SubsonicService.shared
        let place = connection.map { " on \(service.displayName(of: $0))" } ?? ""
        guard let input = await Dialogs.promptForText(
            title: "New Playlist",
            message: "Enter a name for the new playlist\(place):",
            placeholder: "Playlist name",
            confirmTitle: "Create"
        ) else { return }

        do {
            if let connection {
                try await SubsonicPlaylists.shared.createPlaylist(named: input, on: connection)
            } else {
                try store.create(named: input)
            }
        } catch {
            await Dialogs.showError(describe(error))
        }
    }

    static func rename(_ id: PlaylistID) async {
        let name = store.displayName(of: id)
        guard let input = await Dialogs.promptForText(
            title: "Rename Playlist",
            message: "Enter a new name for “\(name)”:",
            initial: name,
            placeholder: "Playlist name",
            confirmTitle: "Rename"
        ) else { return }

        do {
            if id.isRemote {
                try await SubsonicPlaylists.shared.renamePlaylist(id, to: input)
            } else if let local = id.localName {
                try await store.rename(local, to: input)
            }
        } catch {
            await Dialogs.showError(describe(error))
        }
    }

    static func delete(_ id: PlaylistID) async {
        let name = store.displayName(of: id)
        let message: String
        if id.isRemote {
            let server = store.connectionName(of: id) ?? "the server"
            message = "Are you sure you want to delete “\(name)”? It is deleted on \(server) as well, and so are the copy of it kept here and the files downloaded for its songs. This can't be undone."
        } else {
            guard store.names.count > 1 else {
                await Dialogs.showError(PlaylistError.lastPlaylist.localizedDescription)
                return
            }
            message = "Are you sure you want to delete “\(name)”? This can't be undone."
        }

        guard await Dialogs.confirm(
            title: "Delete Playlist",
            message: message,
            confirmTitle: "Delete",
            destructive: true
        ) else { return }

        do {
            if id.isRemote {
                try await SubsonicPlaylists.shared.deletePlaylist(id)
            } else if let local = id.localName {
                try await store.delete(local)
            }
        } catch {
            await Dialogs.showError(describe(error))
        }
    }

    /// "Download All Tracks Automatically" on or off for a playlist of a server. Turning it on is confirmed first: the
    /// files take room that the cache size doesn't limit.
    static func setAutoDownload(_ enabled: Bool, for id: PlaylistID) async {
        guard id.isRemote, store.remoteInfo(id) != nil else { return }
        if enabled {
            let name = store.displayName(of: id)
            let server = store.connectionName(of: id) ?? "the server"
            let count = store.playlist(id)?.trackCount ?? store.remoteInfo(id)?.songCount ?? 0
            let tracks = count > 0 ? "all \(count) track(s)" : "all tracks"
            guard await Dialogs.confirm(
                title: "Download All Tracks Automatically",
                message: "This downloads \(tracks) of “\(name)” from \(server) now, and the tracks added to it later as they come. "
                    + "The files are kept on this Mac for as long as this is on: the cache size of the connection doesn't apply "
                    + "to them (they don't count towards it either), so they take as much disk space as the tracks need.\n\n"
                    + "Turning it off makes them ordinary downloads again, which the cache size applies to: they are deleted "
                    + "when the cache is full, or right away if the connection has no cache.",
                confirmTitle: "Download All"
            ) else { return }
        }
        await SubsonicAutoDownloads.shared.setEnabled(enabled, for: id)
    }

    /// "Don't group by albums" off or on for the active playlist. Grouping a playlist of a server can reorder its tracks,
    /// and the new order is saved on the server: the user is asked first.
    static func setFlat(_ flat: Bool) async {
        let id = store.activeID
        if !flat, let info = store.remoteInfo(id), info.isOwnEditable {
            guard store.canEdit(id) else {
                let reason = SubsonicPlaylists.shared.readOnlyReason(id) ?? "it can't be changed now"
                await Dialogs.showError("Grouping by albums can reorder the tracks, which can't be saved on the server now: \(reason).",
                                        title: "Can't Group")
                return
            }
            let server = store.connectionName(of: id) ?? "the server"
            guard await Dialogs.confirm(
                title: "Group by Albums",
                message: "Grouping puts the tracks of an album together, which can reorder the tracks of “\(info.name)”. The new order is saved on \(server) as well.",
                confirmTitle: "Group"
            ) else { return }
        }
        await store.setFlat(flat)
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? SubsonicError { return SubsonicService.sentence(error.message) }
        return error.localizedDescription
    }
}

/// The "Format:" popup under the file name of the export panel. Changing it swaps the extension in the name field.
@MainActor
private final class ExportFormatPicker: NSObject {
    private let panel: NSSavePanel
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))

    var format: PlaylistFormat { PlaylistFormat.allCases[max(popup.indexOfSelectedItem, 0)] }

    init(panel: NSSavePanel, name: String) {
        self.panel = panel
        super.init()

        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 0, y: 8, width: 56, height: 20)
        label.alignment = .right
        popup.frame = NSRect(x: 62, y: 5, width: 200, height: 26)
        popup.addItems(withTitles: PlaylistFormat.allCases.map { ".\($0.fileExtension)" })
        popup.target = self
        popup.action = #selector(formatChanged)
        view.addSubview(label)
        view.addSubview(popup)

        panel.nameFieldStringValue = name
        apply()
    }

    @objc private func formatChanged() { apply() }

    private func apply() {
        var stem = panel.nameFieldStringValue
        if PlaylistFormat(fileExtension: (stem as NSString).pathExtension) != nil {
            stem = (stem as NSString).deletingPathExtension
        }
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"
    }
}
