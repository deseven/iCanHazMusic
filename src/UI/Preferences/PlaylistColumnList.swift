// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The columns of the track rows of one `PlaylistMode` as a list that is edited in place (`ToggleItemList`): the eye
/// shows or hides a column, and dragging a row moves it.
struct PlaylistColumnList: View {
    @Bindable var settings: PlaylistSettings
    let mode: PlaylistMode

    var body: some View {
        ToggleItemList(
            items: settings[columns: mode].items.map { .init(id: $0.column, title: $0.column.title, isVisible: $0.isVisible) },
            toggle: { settings[columns: mode].toggle($0) },
            move: { settings[columns: mode].move(from: $0, to: $1) }
        )
        // A drag in progress belongs to the list of one mode.
        .id(mode)
    }
}
