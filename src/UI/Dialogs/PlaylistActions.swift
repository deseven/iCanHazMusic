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
        guard playlist.trackCount > 0, let window = await MainWindowOpener.shared.show() else { return }

        let panel = NSSavePanel()
        panel.message = "Export the playlist to a file"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        let picker = ExportFormatPicker(panel: panel, name: store.activeName)
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

        let data = PlaylistExchange.data(for: playlist.entries, format: format)
        do {
            try data.write(to: url, options: .atomic)
            Log.info("exported \(playlist.trackCount) tracks to \(url.path)")
        } catch {
            Log.error("can't export playlist to \(url.path): \(error.localizedDescription)")
            await Dialogs.showError("The playlist couldn't be saved: \(error.localizedDescription)", title: "Export Failed")
        }
    }

    static func create() async {
        guard let input = await Dialogs.promptForText(
            title: "New Playlist",
            message: "Enter a name for the new playlist:",
            placeholder: "Playlist name",
            confirmTitle: "Create"
        ) else { return }

        do {
            try store.create(named: input)
        } catch {
            await Dialogs.showError(error.localizedDescription)
        }
    }

    static func rename(_ name: String) async {
        guard let input = await Dialogs.promptForText(
            title: "Rename Playlist",
            message: "Enter a new name for “\(name)”:",
            initial: name,
            placeholder: "Playlist name",
            confirmTitle: "Rename"
        ) else { return }

        do {
            try await store.rename(name, to: input)
        } catch {
            await Dialogs.showError(error.localizedDescription)
        }
    }

    static func delete(_ name: String) async {
        guard store.names.count > 1 else {
            await Dialogs.showError(PlaylistError.lastPlaylist.localizedDescription)
            return
        }

        guard await Dialogs.confirm(
            title: "Delete Playlist",
            message: "Are you sure you want to delete “\(name)”? This can't be undone.",
            confirmTitle: "Delete",
            destructive: true
        ) else { return }

        do {
            try await store.delete(name)
        } catch {
            await Dialogs.showError(error.localizedDescription)
        }
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
