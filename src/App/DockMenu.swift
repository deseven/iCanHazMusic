import AppKit

/// The menu shown when right-clicking the Dock icon (the one of the PureBasic version): what plays, and the
/// transport commands. The system adds its own items below ("Options", "Show All Windows", "Hide", "Quit").
/// AppKit asks for the menu every time it is about to be shown, so it is built from the current state each time.
///
/// Like in the old version, everything but Play only exists while a track is playing or paused.
extension AppDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let playback = PlaybackState.shared
        let stopped = playback.isStopped

        let menu = NSMenu()
        menu.autoenablesItems = false

        if let info = playback.info, !stopped {
            for text in [info.artist, info.title] where !text.isEmpty {
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // While stopped, "Play" starts the track under the playlist cursor, like the play button does.
        let canPlay = !stopped || (playback.cursorRow != nil && !PlaylistStore.shared.isLoading)
        addItem(to: menu, playback.status == .playing ? "Pause" : "Play", #selector(dockPlayPause), enabled: canPlay)

        if !stopped {
            addItem(to: menu, "Next Track", #selector(dockNextTrack))
            addItem(to: menu, "Previous Track", #selector(dockPreviousTrack))
            addItem(to: menu, "Next Album", #selector(dockNextAlbum))
            addItem(to: menu, "Previous Album", #selector(dockPreviousAlbum))
            addItem(to: menu, "Stop", #selector(dockStop))
        }

        return menu
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func dockPlayPause() {
        let playback = PlaybackState.shared
        if playback.isStopped {
            guard let row = playback.cursorRow else { return }
            playback.play(row: row)
        } else {
            playback.togglePause()
        }
    }

    @objc private func dockNextTrack() { PlaybackState.shared.nextTrack() }
    @objc private func dockPreviousTrack() { PlaybackState.shared.previousTrack() }
    @objc private func dockNextAlbum() { PlaybackState.shared.nextAlbum() }
    @objc private func dockPreviousAlbum() { PlaybackState.shared.previousAlbum() }
    @objc private func dockStop() { PlaybackState.shared.stop() }
}
