import AppKit
import UniformTypeIdentifiers

/// Entry points for adding files to the active playlist (File menu, drag and drop) and for re-reading the tags of
/// files that are in it. Runs one `ImportSession` at a time behind a modal progress sheet.
@MainActor
@Observable
final class ImportCoordinator {
    static let shared = ImportCoordinator()

    /// The running import, if any. Menu items and drops are ignored while this is set.
    private(set) var session: ImportSession?

    /// An import is running, or the active playlist is still loading (adding to it would be unsafe).
    var isBusy: Bool { session != nil || PlaylistStore.shared.isLoading }

    private init() {}

    // MARK: - Entry points

    func addDirectory() async {
        let panel = NSOpenPanel()
        panel.message = "Choose directories to add to the playlist"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        await runPanel(panel)
    }

    func addFiles() async {
        let panel = NSOpenPanel()
        panel.message = "Choose files to add to the playlist"
        panel.prompt = "Add"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AudioFileGatherer.supportedExtensions.sorted()
            .compactMap { UTType(filenameExtension: $0) }
        await runPanel(panel)
    }

    func importPlaylists() async {
        let panel = NSOpenPanel()
        panel.message = "Choose playlist files to add to the playlist"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PlaylistFormat.allCases.compactMap { UTType(filenameExtension: $0.fileExtension) }
        await runPanel(panel, playlists: true)
    }

    /// Files and/or directories dropped on the window. Returns whether the drop was accepted.
    ///
    /// Playlist files are only imported if nothing but playlist files was dropped. In a mix with audio files or
    /// directories they are ignored, as albums often carry a playlist of their own and importing it as well would
    /// add every track twice.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        let urls = urls.filter(\.isFileURL)
        guard !isBusy, !urls.isEmpty else { return false }
        let playlistsOnly = urls.allSatisfy(PlaylistExchange.isPlaylistFile)
        Task { await start(urls, playlists: playlistsOnly) }
        return true
    }

    /// Reads the tags of these files again (and their album art), then takes them over into the active playlist,
    /// which is regrouped, as the new tags can put a track into another album. Files that can't be read keep
    /// their old values.
    func reloadTags(of files: [URL]) async {
        guard !isBusy, !files.isEmpty, let window = Dialogs.hostWindow else { return }

        let store = PlaylistStore.shared
        let name = store.activeName
        let session = ImportSession(tagParsingConcurrency: store.effectiveTagParsingConcurrency)
        self.session = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)

        let outcome = await session.reload(files: files)
        CoverCache.reset()
        if !outcome.aborted {
            await store.applyTags(outcome.results, to: name)
        }

        await sheet.dismiss()
        self.session = nil

        if !outcome.aborted, session.failed > 0 {
            await Dialogs.showError(
                "\(session.failed) of \(files.count) file(s) couldn't be read or have no tags. They keep their previous tags.",
                title: "Reload Incomplete"
            )
        }
    }

    // MARK: - Internals

    private func runPanel(_ panel: NSOpenPanel, playlists: Bool = false) async {
        guard !isBusy, let window = Dialogs.hostWindow, window.isVisible else { return }
        guard await panel.beginSheetModal(for: window) == .OK else { return }
        await start(panel.urls, playlists: playlists)
    }

    /// `playlists`: `urls` are playlist files whose entries are imported; otherwise they are audio files and
    /// directories (playlist files among them are ignored by the gatherer).
    private func start(_ urls: [URL], playlists: Bool = false) async {
        guard !isBusy, !urls.isEmpty, let window = Dialogs.hostWindow else { return }

        let session = ImportSession(tagParsingConcurrency: PlaylistStore.shared.effectiveTagParsingConcurrency)
        self.session = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)

        let outcome = playlists ? await session.run(playlists: urls) : await session.run(inputs: urls)
        CoverCache.reset()   // the import may have found art for albums that currently show a placeholder
        if !outcome.aborted {
            await PlaylistStore.shared.append(outcome.albums, to: PlaylistStore.shared.activeName)
        }

        await sheet.dismiss()
        self.session = nil

        if outcome.fileCount == 0, !outcome.aborted {
            await Dialogs.showError(
                playlists ? "The playlist(s) don't list any supported audio files." : "No supported audio files were found.",
                title: "Nothing to Add"
            )
        }
    }
}
