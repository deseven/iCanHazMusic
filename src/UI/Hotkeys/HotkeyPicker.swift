// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

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
