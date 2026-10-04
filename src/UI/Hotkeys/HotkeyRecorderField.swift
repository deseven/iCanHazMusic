import AppKit

extension NSEvent.ModifierFlags {
    /// The modifiers a hotkey can have (Caps Lock, Fn etc. are dropped).
    var hotkeyModifiers: HotkeyModifiers {
        var result: HotkeyModifiers = []
        if contains(.control) { result.insert(.control) }
        if contains(.option) { result.insert(.option) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.command) { result.insert(.command) }
        return result
    }
}

/// A field that records a key combination: click it, press the keys. Ported from iCanHazShortcut's
/// `ShortcutPickerField`.
///
/// - While recording it shows the modifiers held; a key that completes a valid combination (see `Hotkey`) ends the
///   recording. A key without a usable modifier is shown greyed out and doesn't end it.
/// - Esc cancels (the previous hotkey stays), Return ends the recording without a change, Delete clears the hotkey,
///   Tab moves on in the key view loop.
/// - Recording ends when the window loses focus or goes away, so it can never get stuck: while it runs, the global
///   hotkeys are off (`onRecordingChange`).
final class HotkeyRecorderField: NSView {
    /// The recorded combination; nil = none. Setting it doesn't call `onChange`.
    var hotkey: Hotkey? {
        didSet { if !isRecording { refresh() } }
    }

    /// The user recorded a combination (or cleared it).
    var onChange: ((Hotkey?) -> Void)?
    /// Recording started or ended.
    var onRecordingChange: ((Bool) -> Void)?

    var isEnabled = true {
        didSet { refresh() }
    }

    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            onRecordingChange?(isRecording)
        }
    }

    private var heldModifiers: HotkeyModifiers = []
    /// A key that was pressed without a combination that can be used (shown greyed out until the next event).
    private var rejectedKey: String?
    private var resignObserver: NSObjectProtocol?

    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton(frame: .zero)

    private static let size = NSSize(width: 170, height: 22)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1

        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear hotkey")
        clearButton.imagePosition = .imageOnly
        clearButton.isBordered = false
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.toolTip = "Clear hotkey"
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -2),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        refresh()
    }

    override var intrinsicContentSize: NSSize { Self.size }

    // MARK: - Appearance

    /// Shows the state: what the label says, and the colors (which depend on the appearance, so they are set
    /// whenever it changes).
    private func refresh() {
        let text: String
        var color = NSColor.labelColor
        if !isEnabled {
            text = hotkey?.string ?? ""
            color = .disabledControlTextColor
        } else if isRecording {
            if let rejectedKey {
                text = rejectedKey
                color = .disabledControlTextColor
            } else if !heldModifiers.isEmpty {
                text = heldModifiers.symbols
                color = .tertiaryLabelColor
            } else {
                text = "Press keys…"
                color = .placeholderTextColor
            }
        } else if let hotkey {
            text = hotkey.string
        } else {
            text = "Click to record"
            color = .placeholderTextColor
        }
        label.stringValue = text
        label.textColor = color
        clearButton.isHidden = isRecording || !isEnabled || hotkey == nil

        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = (isRecording
                ? NSColor.controlAccentColor.withAlphaComponent(0.08)
                : isEnabled ? NSColor.textBackgroundColor : NSColor.controlBackgroundColor).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    // MARK: - Window

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if newWindow == nil { stopRecording() }
        if let newWindow {
            // Switching to another app leaves the field the first responder; recording must not outlive the focus.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelRecording() }
            }
        }
    }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if window?.firstResponder === self {
            if !isRecording { startRecording() }   // after Esc or Return it still is the first responder
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        guard isEnabled, super.becomeFirstResponder() else { return false }
        startRecording()
        return true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { stopRecording() }
        return resigned
    }

    // MARK: - Recording

    private func startRecording() {
        heldModifiers = []
        rejectedKey = nil
        isRecording = true
        refresh()
    }

    private func stopRecording() {
        heldModifiers = []
        rejectedKey = nil
        isRecording = false
        refresh()
    }

    /// Ends the recording without a change and gives up the focus.
    private func cancelRecording() {
        guard isRecording else { return }
        stopRecording()
        window?.makeFirstResponder(nil)
    }

    // MARK: - Keys

    /// Command combinations would otherwise reach the menu bar (⌘Q, ⌘W, ⌘, ...) before `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        let keyCode = UInt32(event.keyCode)
        let modifiers = event.modifierFlags.hotkeyModifiers

        if modifiers.isEmpty {
            switch Int(keyCode) {
            case 0x35:   // Esc
                cancelRecording()
                return
            case 0x24, 0x4C:   // Return, Enter
                stopRecording()
                window?.makeFirstResponder(nil)
                return
            case 0x33, 0x75:   // Delete, Forward Delete
                hotkey = nil
                onChange?(nil)
                stopRecording()
                window?.makeFirstResponder(nil)
                return
            default:
                break
            }
        }
        if keyCode == 0x30, modifiers.isDisjoint(with: [.control, .option, .command]) {   // Tab, Shift-Tab
            stopRecording()
            super.keyDown(with: event)
            return
        }

        guard let name = Hotkey.keyName(for: keyCode) else {
            NSSound.beep()
            return
        }
        guard let recorded = Hotkey(keyCode: keyCode, modifiers: modifiers) else {
            rejectedKey = name   // needs a modifier
            refresh()
            return
        }

        hotkey = recorded
        onChange?(recorded)
        stopRecording()
        window?.makeFirstResponder(nil)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        heldModifiers = event.modifierFlags.hotkeyModifiers
        rejectedKey = nil
        refresh()
    }

    @objc private func clearClicked() {
        hotkey = nil
        onChange?(nil)
    }

    // MARK: - Accessibility

    override func accessibilityLabel() -> String? {
        hotkey.map { "Hotkey: \($0.string)" } ?? "Hotkey (none)"
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}
