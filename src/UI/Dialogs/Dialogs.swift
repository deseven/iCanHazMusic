import AppKit

/// Thin async wrapper over `NSAlert`. Alerts are shown as sheets on the main window when possible.
@MainActor
enum Dialogs {
    /// Window the dialogs attach to; set once the main window exists.
    static weak var hostWindow: NSWindow?

    /// Asks for a single line of text. Returns `nil` if cancelled.
    static func promptForText(
        title: String,
        message: String,
        initial: String = "",
        placeholder: String = "",
        confirmTitle: String
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func showError(_ message: String, title: String = "Error") async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    /// Asks a yes/no question. The confirm button is marked destructive if requested.
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        destructive: Bool = false
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let confirmButton = alert.addButton(withTitle: confirmTitle)
        confirmButton.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    private static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = hostWindow, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}
