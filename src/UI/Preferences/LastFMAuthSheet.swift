// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Window-modal sheet shown while the user confirms the Last.fm connection in the browser: a spinner, a hint and an
/// Abort button. Same mechanics as `ImportProgressSheet`.
@MainActor
final class LastFMAuthSheet {
    private let panel: NSWindow
    private weak var parent: NSWindow?
    private var closed: AsyncStream<Void>?

    init(onAbort: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: LastFMAuthView(onAbort: onAbort))
        hosting.sizingOptions = [.preferredContentSize]
        panel = NSWindow(contentViewController: hosting)
        panel.styleMask = [.titled]
    }

    func present(on window: NSWindow) {
        parent = window
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        closed = stream
        window.beginSheet(panel) { _ in continuation.finish() }
    }

    /// Closes the sheet and returns once it is really gone (so an alert can follow).
    func dismiss() async {
        guard let parent, let closed else { return }
        self.closed = nil
        parent.endSheet(panel)
        for await _ in closed {}
    }
}

private struct LastFMAuthView: View {
    let onAbort: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for the confirmation from Last.fm...").font(.headline)
            }

            Text("Allow \(AppConstants.appName) to access your account in the browser, then come back here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Abort", action: onAbort)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: Layout.lastFMSheetWidth)
    }
}
