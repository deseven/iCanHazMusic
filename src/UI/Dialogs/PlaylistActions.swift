import Foundation

/// User-facing playlist operations: ask, validate, perform, report errors.
@MainActor
enum PlaylistActions {
    private static var store: PlaylistStore { .shared }

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
