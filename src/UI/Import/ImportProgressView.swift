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
                Button(session.isAborting || session.stage == .appending ? "Aborting..." : "Abort") {
                    session.abort()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(session.isAborting || session.stage == .appending)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: Layout.importSheetWidth)
    }

    private var title: String {
        switch session.stage {
        case .gathering: "Gathering the list of files..."
        case .reading: "Reading tags..."
        case .appending: "Appending to current playlist..."
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
