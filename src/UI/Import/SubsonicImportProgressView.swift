// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Content of the modal progress sheet of adding Subsonic tracks (`SubsonicImportSession`): spinner + stage title and an
/// Abort button. Looks like `ImportProgressView`.
struct SubsonicImportProgressView: View {
    let session: SubsonicImportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title).font(.headline)
            }

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
        case .loading: "Reading the playlist from the server..."
        case .appending: "Appending to current playlist..."
        }
    }
}
