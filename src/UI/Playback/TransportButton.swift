// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct TransportButton: View {
    /// The height of a button, and the width it takes when there is room: up to eight of them are in a row, which
    /// shrink (to `minWidth`) when the block is too narrow for that.
    static let side: CGFloat = 32
    private static let minWidth: CGFloat = 24

    let symbol: String
    let help: String
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(minWidth: Self.minWidth, maxWidth: Self.side, minHeight: Self.side, maxHeight: Self.side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
