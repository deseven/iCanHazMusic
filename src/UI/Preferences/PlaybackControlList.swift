// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The buttons of the Playback Controls as a list that is edited in place (`ToggleItemList`, with the rows and the
/// dragging of `NowPlayingComponentList`): the eye shows or hides a button, and dragging a row moves it.
struct PlaybackControlList: View {
    @Bindable var settings: NowPlayingSettings

    var body: some View {
        ToggleItemList(
            items: settings.controls.items.map { .init(id: $0.control, title: $0.control.title, isVisible: $0.isVisible) },
            toggle: { settings.controls.toggle($0) },
            move: { settings.controls.move(from: $0, to: $1) }
        )
    }
}
