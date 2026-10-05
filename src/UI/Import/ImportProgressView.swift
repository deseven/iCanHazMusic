// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Content of the modal progress sheet: spinner + stage title, statistics once files are being read,
/// and an Abort button.
struct ImportProgressView: View {
    let session: ImportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title).font(.headline)
            }

            statistics

            HStack {
                Spacer()
                Button(session.isAborting || session.isFinishing ? "Aborting..." : "Abort") {
                    session.abort()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(session.isAborting || session.isFinishing)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: Layout.importSheetWidth)
    }

    private var title: String {
        switch session.stage {
        case .gathering: "Gathering the list of files..."
        case .reading: "Reading tags, album art and lyrics..."
        case .appending: "Appending to current playlist..."
        case .updating: "Updating the playlist..."
        }
    }

    @ViewBuilder
    private var statistics: some View {
        if session.stage != .gathering {
            // The timeline keeps the speed ticking even when no file finishes for a while.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Files processed", "\(session.processed) / \(session.total)")
                    row("Successful reads", "\(session.successful)")
                    row("Incomplete tags", "\(session.incomplete)")
                    row("Failed", "\(session.failed)")
                    row("Albums processed", "\(session.albumsProcessed)")
                    row("Album arts processed", "\(session.artsProcessed)")
                    row("Lyrics", "\(session.lyricsFound)")
                    row("Speed", String(format: "%.1f files/s", session.speed(at: context.date)))
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
