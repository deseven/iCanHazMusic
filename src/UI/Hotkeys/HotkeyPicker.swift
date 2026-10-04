import SwiftUI

/// SwiftUI wrapper around `HotkeyRecorderField`.
struct HotkeyPicker: NSViewRepresentable {
    let hotkey: Hotkey?
    let onChange: (Hotkey?) -> Void
    let onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderField {
        HotkeyRecorderField()
    }

    func updateNSView(_ field: HotkeyRecorderField, context: Context) {
        field.hotkey = hotkey
        field.onChange = onChange
        field.onRecordingChange = onRecordingChange
    }
}
