// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// What the update sheet shows besides the release, and where its buttons report to.
@MainActor
@Observable
final class UpdateSheetModel {
    enum Choice {
        case later
        case skip
        case update
    }

    /// While set, the buttons are replaced by this text and a spinner.
    var progress: String?
    @ObservationIgnored fileprivate var onChoice: ((Choice) -> Void)?

    fileprivate func choose(_ choice: Choice) {
        guard let onChoice else { return }
        self.onChoice = nil
        onChoice(choice)
    }
}

/// Window-modal sheet that offers a release: its title, the changelog and the choice between skipping that
/// version, deciding later and updating. Same mechanics as `LastFMAuthSheet`: `run` returns the choice while the
/// sheet is still open (it then shows `model.progress` during the installation), `dismiss` closes it.
@MainActor
final class UpdateSheet {
    let model = UpdateSheetModel()
    private let panel: NSWindow
    private weak var parent: NSWindow?
    private var closed: AsyncStream<Void>?

    init(update: UpdateInfo) {
        let hosting = NSHostingController(rootView: UpdateView(update: update, model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel = NSWindow(contentViewController: hosting)
        panel.styleMask = [.titled]
    }

    func run(on window: NSWindow) async -> UpdateSheetModel.Choice {
        parent = window
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        closed = stream
        window.beginSheet(panel) { _ in continuation.finish() }
        return await withCheckedContinuation { continuation in
            model.onChoice = { continuation.resume(returning: $0) }
        }
    }

    /// Closes the sheet and returns once it is really gone (so an alert can follow).
    func dismiss() async {
        guard let parent, let closed else { return }
        self.closed = nil
        parent.endSheet(panel)
        for await _ in closed {}
    }
}

private struct UpdateView: View {
    let update: UpdateInfo
    let model: UpdateSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A new version of \(AppConstants.appName) was found.")
                .font(.headline)

            Text(update.releaseTitle)
                .font(.title3.bold())

            ScrollView {
                Text(update.changelog)
                    .font(.system(size: NSFont.smallSystemFontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: Layout.updateChangelogHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))

            if let progress = model.progress {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                }
                .padding(.top, 8)
            } else {
                Text("Would you like to update?")
                    .padding(.top, 8)
                HStack(spacing: 12) {
                    Spacer()
                    Button("Skip this version") { model.choose(.skip) }
                    Button("Later") { model.choose(.later) }
                        .keyboardShortcut(.cancelAction)
                    Button("Update") { model.choose(.update) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: Layout.updateSheetWidth)
    }
}
