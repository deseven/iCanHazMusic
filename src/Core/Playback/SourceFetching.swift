// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What is wrong with getting a remote track as a file: a message for the log and the playlist (not a sentence).
struct SourceFetchError: LocalizedError, Equatable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A claim on the local file of a track that is not in a file of this Mac (a song on a Subsonic server): while somebody
/// holds the lease the file is there (or being made), when the last one lets go of it the file is deleted.
///
/// The decoder of a track holds one for as long as it exists, the engine one for the track it will play next (so that it
/// is downloaded in good time, see `PlaybackEngine.prefetchLead`), the waveform one while it measures the track.
final class SourceLease: @unchecked Sendable {
    private let wait: @Sendable () async throws -> URL
    private let release: @Sendable () -> Void
    private let measure: @Sendable () -> Double?

    /// `progress`: how much of the file is there, 0...1, or nil if that can't be told (see `progress()`).
    init(wait: @escaping @Sendable () async throws -> URL, release: @escaping @Sendable () -> Void,
         progress: @escaping @Sendable () -> Double? = { nil }) {
        self.wait = wait
        self.release = release
        self.measure = progress
    }

    /// How much of the file has been fetched (0...1) while it is being fetched; nil when there is nothing to measure:
    /// the size isn't known (yet), or the file is there already.
    func progress() -> Double? {
        measure()
    }

    /// The local file, once it is there. Waits for the download; throws `CancellationError` if the waiting task is
    /// cancelled, `SourceFetchError` (or whatever the fetcher throws) if the file can't be had.
    func file() async throws -> URL {
        try await wait()
    }

    deinit { release() }
}

/// Makes the audio of tracks that don't live in a file of this Mac available as one.
protocol SourceFetching: Sendable {
    /// Whether `url` (a `PlaybackSource.url`) is one of the fetcher's.
    func handles(_ url: URL) -> Bool

    /// Starts getting the file of `url` if nobody is yet, and claims it. Cheap and immediate: the work happens in the
    /// background, `SourceLease.file()` waits for it.
    func acquire(_ url: URL) -> SourceLease
}
