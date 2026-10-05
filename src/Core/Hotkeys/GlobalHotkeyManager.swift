// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Carbon
import Foundation

/// Identifies a registered hotkey.
struct HotkeyID: Hashable {
    let value: UInt32
}

enum HotkeyError: Error, CustomStringConvertible {
    case handlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)

    /// `RegisterEventHotKey` says the combination is taken (by the system or another app).
    var isAlreadyTaken: Bool {
        if case .registrationFailed(let status) = self { return status == OSStatus(eventHotKeyExistsErr) }
        return false
    }

    var description: String {
        switch self {
        case .handlerInstallFailed(let status): "InstallEventHandler failed with status \(status)"
        case .registrationFailed(let status):
            isAlreadyTaken ? "the combination is already in use" : "RegisterEventHotKey failed with status \(status)"
        }
    }
}

/// Where hotkeys are registered. `GlobalHotkeyManager` is the real one; tests use a stub.
@MainActor
protocol HotkeyBackend: AnyObject {
    /// `handler` runs on the main actor every time the combination is pressed, in any app.
    func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) throws -> HotkeyID
    func unregister(_ id: HotkeyID)
}

/// System-wide hotkeys through Carbon's `RegisterEventHotKey`: no permissions needed, the combination is consumed
/// (the app in front doesn't see it). A combination that is taken already (by the system or another app) fails.
///
/// (Carbon is the only API that does this without Accessibility/Input Monitoring; it is old but not deprecated.)
@MainActor
final class GlobalHotkeyManager: HotkeyBackend {
    static let shared = GlobalHotkeyManager()

    private struct Entry {
        let ref: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    private let signature = GlobalHotkeyManager.fourCharCode("ichm")
    private var entries: [HotkeyID: Entry] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {}

    func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) throws -> HotkeyID {
        try installEventHandler()

        let id = HotkeyID(value: nextID)
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers.carbonFlags,
                                         EventHotKeyID(signature: signature, id: id.value),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotkeyError.registrationFailed(status) }
        entries[id] = Entry(ref: ref, handler: handler)
        return id
    }

    func unregister(_ id: HotkeyID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    // MARK: - Events

    private func installEventHandler() throws {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                // Application events are delivered on the main thread.
                MainActor.assumeIsolated { manager.hotkeyPressed(HotkeyID(value: hotKeyID.id)) }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { throw HotkeyError.handlerInstallFailed(status) }
    }

    private func hotkeyPressed(_ id: HotkeyID) {
        entries[id]?.handler()
    }

    /// A 4-character ASCII string as `FourCharCode`.
    static func fourCharCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
