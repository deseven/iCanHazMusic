// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import UniformTypeIdentifiers

/// Entry points for adding files to the active playlist (File menu, drag and drop; only for a playlist of this Mac, a
/// playlist of a Subsonic server takes tracks of its server, see `addSubsonic`) and for re-reading the tags of files that
/// are in it. Runs one `ImportSession` at a time behind a modal progress sheet.
@MainActor
@Observable
final class ImportCoordinator {
    static let shared = ImportCoordinator()

    /// The running import, if any. Menu items and drops are ignored while this is set.
    private(set) var session: ImportSession?

    /// The running addition of Subsonic tracks, if any (the same: nothing else starts while it is set).
    private(set) var subsonicSession: SubsonicImportSession?

    /// An import is running, or the active playlist is still loading (adding to it would be unsafe).
    var isBusy: Bool { session != nil || subsonicSession != nil || PlaylistStore.shared.isLoading }

    /// Files can be added to the shown playlist: it is one of this Mac and not the queue that is shown in its place.
    var canAddFiles: Bool {
        let store = PlaylistStore.shared
        return !isBusy && !store.activeID.isRemote && !(store.isQueueShown && PlaybackState.shared.queue.isEnabled)
    }

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
        panel.allowedContentTypes = (AudioFileGatherer.supportedExtensions.sorted() + ["cue"])
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

    /// Files and/or directories dropped on the window (CUE sheets among them add their tracks). Returns whether the drop was accepted.
    ///
    /// Playlist files are only imported if nothing but playlist files was dropped. In a mix with audio files or
    /// directories they are ignored, as albums often carry a playlist of their own and importing it as well would
    /// add every track twice.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        let urls = urls.filter(\.isFileURL)
        // Files go into the active playlist, which isn't what the queue view shows, and isn't one of a server.
        guard canAddFiles, !urls.isEmpty else { return false }
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
        let name = store.activeID
        let session = ImportSession(tagParsingConcurrency: store.effectiveTagParsingConcurrency)
        self.session = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)

        let outcome = await session.reload(files: files)
        CoverCache.reset()
        LyricsService.shared.refreshCurrent()
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

    /// Reads exactly these files, in this order, into the active playlist (the playlist of the previous version,
    /// see `MigrationActions`). Returns how many files there were and how many of them couldn't be read, `nil` if the
    /// import didn't happen or was aborted.
    func importList(_ files: [URL]) async -> (total: Int, failed: Int)? {
        guard !isBusy, !files.isEmpty, let window = Dialogs.hostWindow else { return nil }

        let session = ImportSession(tagParsingConcurrency: PlaylistStore.shared.effectiveTagParsingConcurrency)
        self.session = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)

        let outcome = await session.run(files: files)
        CoverCache.reset()
        LyricsService.shared.refreshCurrent()
        if !outcome.aborted {
            await PlaylistStore.shared.append(outcome.albums, to: PlaylistStore.shared.activeID)
        }

        await sheet.dismiss()
        self.session = nil
        return outcome.aborted ? nil : (outcome.fileCount, session.failed)
    }

    /// Adds Subsonic tracks to a playlist of their server behind the progress sheet: `albums` makes what is added, then the
    /// songs are added to the playlist on the server (their covers are fetched when something shows them, see
    /// `SubsonicCovers`). Nothing is added if that is aborted or fails (the user is told of a failure).
    func addSubsonic(from connection: SubsonicConnection, to playlist: PlaylistID,
                     albums: @escaping @MainActor () async throws -> [Album]) async {
        guard !isBusy, let window = Dialogs.hostWindow else { return }

        let session = SubsonicImportSession()
        subsonicSession = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)

        let outcome = await session.run(albums: albums)
        var failure: String?
        if !outcome.aborted, outcome.error == nil, !outcome.albums.isEmpty {
            session.beginAppending()
            let songs = outcome.albums.flatMap { $0.tracks.compactMap { $0.subsonic?.songID } }
            do {
                try await SubsonicPlaylists.shared.append(songIDs: songs, to: playlist)
                Log.info("subsonic: added \(songs.count) track(s) of \(outcome.albums.count) album(s) from \"\(connection.name)\" to '\(PlaylistStore.shared.displayName(of: playlist))'")
            } catch {
                let text = (error as? SubsonicError)?.message ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Log.error("subsonic: can't add the tracks to '\(PlaylistStore.shared.displayName(of: playlist))': \(text)")
                failure = SubsonicService.sentence(text)
            }
        }

        await sheet.dismiss()
        self.subsonicSession = nil

        if let error = outcome.error ?? failure {
            await Dialogs.showError(error, title: "Nothing Added")
        } else if !outcome.aborted, outcome.albums.isEmpty {
            await Dialogs.showError("There are no tracks to add.", title: "Nothing to Add")
        }
    }

    // MARK: - Internals

    private func runPanel(_ panel: NSOpenPanel, playlists: Bool = false) async {
        guard !isBusy, let window = await MainWindowOpener.shared.show() else { return }
        guard !isBusy else { return }
        guard await panel.beginSheetModal(for: window) == .OK else { return }
        await start(panel.urls, playlists: playlists)
    }

    /// `playlists`: `urls` are playlist files whose entries are imported; otherwise they are audio files and
    /// directories (playlist files among them are ignored by the gatherer).
    private func start(_ urls: [URL], playlists: Bool = false) async {
        guard !isBusy, !PlaylistStore.shared.activeID.isRemote, !urls.isEmpty, let window = Dialogs.hostWindow else { return }

        let session = ImportSession(tagParsingConcurrency: PlaylistStore.shared.effectiveTagParsingConcurrency)
        self.session = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)

        let outcome = playlists ? await session.run(playlists: urls) : await session.run(inputs: urls)
        CoverCache.reset()   // the import may have found art for albums that currently show a placeholder
        LyricsService.shared.refreshCurrent()
        if !outcome.aborted {
            await PlaylistStore.shared.append(outcome.albums, to: PlaylistStore.shared.activeID)
        }

        await sheet.dismiss()
        self.session = nil

        if outcome.fileCount == 0, !outcome.aborted {
            await Dialogs.showError(
                playlists ? "The playlist(s) don't list any supported audio files." : "No supported audio files or usable CUE sheets were found.",
                title: "Nothing to Add"
            )
        }
    }
}
