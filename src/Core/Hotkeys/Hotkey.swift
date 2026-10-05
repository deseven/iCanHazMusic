// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Carbon
import Foundation

/// The modifier keys a hotkey can have. Own type (instead of `NSEvent.ModifierFlags`) so that Core stays free of AppKit;
/// the UI converts.
struct HotkeyModifiers: OptionSet, Hashable {
    let rawValue: UInt8

    static let control = HotkeyModifiers(rawValue: 1 << 0)
    static let option = HotkeyModifiers(rawValue: 1 << 1)
    static let shift = HotkeyModifiers(rawValue: 1 << 2)
    static let command = HotkeyModifiers(rawValue: 1 << 3)

    /// The flags `RegisterEventHotKey` wants.
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }

    /// Symbols in the canonical order: ⌃⌥⇧⌘.
    var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// A key combination that can be registered as a global hotkey: a physical key (Carbon virtual key code, so it
/// doesn't depend on the keyboard layout) and modifiers.
///
/// Its text form (what the config holds and the UI shows) is the canonical `⌃⌥⇧⌘` symbols followed by the key:
/// `⌘⇧G`, `⌃⌥␣`, `F19`. Only combinations that make sense as a global hotkey exist (see `isValid`).
struct Hotkey: Hashable {
    let keyCode: UInt32
    let modifiers: HotkeyModifiers

    /// `nil` if the key is unknown or the combination isn't a valid hotkey (see `isValid`).
    init?(keyCode: UInt32, modifiers: HotkeyModifiers) {
        guard Self.isValid(keyCode: keyCode, modifiers: modifiers) else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Parses the text form (`⌘⇧G`). Modifier symbols may come in any order, shifted symbols (`⌘!`) stand for their
    /// key (`⌘1`). `nil` for anything that isn't a valid hotkey.
    init?(string: String) {
        var modifiers: HotkeyModifiers = []
        var key = ""
        for character in string {
            switch character {
            case "⌘": modifiers.insert(.command)
            case "⇧": modifiers.insert(.shift)
            case "⌥": modifiers.insert(.option)
            case "⌃": modifiers.insert(.control)
            default: key.append(character)
            }
        }
        guard let keyCode = Self.keyCodes[key] else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    /// The canonical text form.
    var string: String {
        modifiers.symbols + (Self.keyNames[keyCode] ?? "")
    }

    // MARK: - Validation

    /// The key is known and the combination is usable as a global hotkey:
    /// - F-keys and Clear work without modifiers;
    /// - Shift alone only works for keys that aren't typed (F-keys, arrows, navigation...): Shift+letter would
    ///   take over normal typing;
    /// - everything else needs ⌃, ⌥ or ⌘.
    static func isValid(keyCode: UInt32, modifiers: HotkeyModifiers) -> Bool {
        guard let name = keyNames[keyCode] else { return false }
        if validWithoutModifiers.contains(name) { return true }
        if modifiers.isEmpty { return false }
        if modifiers == .shift { return validWithShiftOnly.contains(name) }
        return true
    }

    /// The name of a key as shown in a hotkey (`nil` if it can't be part of one).
    static func keyName(for keyCode: UInt32) -> String? {
        keyNames[keyCode]
    }

    // MARK: - Key tables

    /// Carbon virtual key codes (physical positions on an ANSI keyboard) and how they are written.
    private static let keyNames: [UInt32: String] = [
        // Letters
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
        0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
        0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x1F: "O", 0x20: "U", 0x22: "I",
        0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K", 0x2D: "N",
        0x2E: "M",

        // Numbers
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",

        // Punctuation
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]",
        0x29: ";", 0x27: "'", 0x2A: "\\", 0x2B: ",",
        0x2C: "/", 0x2F: ".", 0x32: "`", 0x0A: "§",

        // Special keys
        0x31: "␣", 0x35: "⎋", 0x24: "↩", 0x4C: "⌤",
        0x39: "⇪", 0x73: "⤒", 0x77: "⤓", 0x74: "⇞",
        0x79: "⇟", 0x33: "⌫", 0x75: "⌦", 0x30: "⇥",

        // Arrows
        0x7E: "↑", 0x7D: "↓", 0x7B: "←", 0x7C: "→",

        // F-keys
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16",
        0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",

        0x47: "Clear",
    ]

    /// The shifted symbols of the keys above, accepted when parsing.
    private static let shiftedNames: [String: UInt32] = [
        "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15, "%": 0x17,
        "^": 0x16, "&": 0x1A, "*": 0x1C, "(": 0x19, ")": 0x1D,
        "_": 0x1B, "+": 0x18, "{": 0x21, "}": 0x1E,
        ":": 0x29, "\"": 0x27, "|": 0x2A, "<": 0x2B,
        "?": 0x2C, ">": 0x2F, "~": 0x32, "±": 0x0A,
    ]

    private static let keyCodes: [String: UInt32] = {
        var table = shiftedNames
        for (code, name) in keyNames { table[name] = code }
        return table
    }()

    private static let fKeys: Set<String> = Set((1...20).map { "F\($0)" })

    private static let validWithoutModifiers: Set<String> = fKeys.union(["Clear"])

    private static let validWithShiftOnly: Set<String> = validWithoutModifiers.union([
        "⎋", "↩", "⌤", "⌫", "⌦", "⇥",
        "⤒", "⤓", "⇞", "⇟",
        "↑", "↓", "←", "→",
    ])
}
