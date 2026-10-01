import SwiftUI

/// Window-modal sheet with the import progress. The parent window is blocked until `dismiss()`.
@MainActor
final class ImportProgressSheet {
    private let panel: NSWindow
    private weak var parent: NSWindow?
    private var closed: AsyncStream<Void>?

    init(session: ImportSession) {
        let hosting = NSHostingController(rootView: ImportProgressView(session: session))
        // The sheet height follows the content (statistics appear once reading starts).
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

    /// Closes the sheet and returns once it is really gone (so another sheet can follow).
    func dismiss() async {
        guard let parent, let closed else { return }
        self.closed = nil
        parent.endSheet(panel)
        for await _ in closed {}
    }
}
