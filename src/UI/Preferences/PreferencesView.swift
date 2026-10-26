// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Preferences window with vertical tabs. Opened from the app menu (⌘,).
/// Every control writes straight through to the setting's owner (`PlaybackState`, `PlaylistStore`, ...), which
/// applies it and keeps it in the config.
struct PreferencesView: View {
    @State private var selectedTab: Tab = .general

    private enum Tab: String, CaseIterable, Identifiable {
        case general
        case engine
        case ui
        case playlist
        case nowPlaying
        case search
        case integrations
        case hotkeys

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: "General"
            case .engine: "Engine"
            case .ui: "UI"
            case .playlist: "Playlist"
            case .nowPlaying: "Now Playing"
            case .search: "Search"
            case .integrations: "Integrations"
            case .hotkeys: "Hotkeys"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .engine: "cpu"
            case .ui: "macwindow"
            case .playlist: "music.note.list"
            case .nowPlaying: "waveform"
            case .search: "magnifyingglass"
            case .integrations: "puzzlepiece.extension"
            case .hotkeys: "keyboard"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Tab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .frame(width: 20)
                            Text(tab.label)
                                .font(.body)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                    .fontWeight(selectedTab == tab ? .medium : .regular)
                }
                Spacer()
            }
            .frame(width: Layout.preferencesTabsWidth)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch selectedTab {
                case .general: GeneralTab()
                case .engine: EngineTab()
                case .ui: UITab()
                case .playlist: PlaylistTab()
                case .nowPlaying: NowPlayingTab()
                case .search: SearchTab()
                case .integrations: IntegrationsTab()
                case .hotkeys: HotkeysTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .frame(width: Layout.preferencesWidth, height: Layout.preferencesHeight)
    }
}

// MARK: - Shared preference row

/// A reusable preference row layout:
///
/// ```
/// title
/// [ control ]
/// description
/// ```
///
/// An `accessory` is shown on the right of the title.
private struct PrefRow<Control: View, Accessory: View>: View {
    let title: String
    let description: Text
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let control: () -> Control

    init(
        title: String, description: String,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.init(title: title, description: Text(description), accessory: accessory, control: control)
    }

    /// For descriptions with more than plain text (a link).
    init(
        title: String, description: Text,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.description = description
        self.accessory = accessory
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body)
                Spacer(minLength: 8)
                accessory()
            }
            control()
            description
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension PrefRow where Accessory == EmptyView {
    init(title: String, description: String, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, description: Text(description), accessory: { EmptyView() }, control: control)
    }

    init(title: String, description: Text, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, description: description, accessory: { EmptyView() }, control: control)
    }
}

/// The page of a tab: rows one below the other, from the top.
private struct TabPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - Tabs

private struct GeneralTab: View {
    @Bindable private var notifications = NotificationService.shared
    @Bindable private var lyrics = LyricsService.shared
    @Bindable private var updates = UpdateService.shared
    @Bindable private var queue = PlaybackState.shared.queue
    @Bindable private var playback = PlaybackState.shared
    @Bindable private var windowSettings = WindowSettings.shared

    var body: some View {
        TabPage {
            PrefRow(
                title: "Close Quits",
                description: "Quit \(AppConstants.appName) when its window is closed. When off, closing the window "
                    + "keeps the music playing in the background; click the Dock icon to bring the window back."
            ) {
                Toggle("", isOn: $windowSettings.closeQuits)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Restore Playback State",
                description: "When \(AppConstants.appName) starts, go on with what was playing when it was quit: the same "
                    + "track, from the same position, playing or paused as it was."
            ) {
                Toggle("", isOn: $playback.restoresState)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(title: "Playback Notifications", description: notificationsDescription) {
                Toggle("", isOn: $notifications.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Lyrics Support",
                description: "Show the lyrics of tracks: a button in the playlist and in the now playing block. Turning this "
                    + "off also turns off the LRCLIB lookup."
            ) {
                Toggle("", isOn: $lyrics.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Enable Queue",
                description: "Queue tracks and albums to play next: press Space on them in a playlist, "
                    + "or use the search window."
            ) {
                Toggle("", isOn: $queue.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Check for Updates",
                description: "Look for a new version of \(AppConstants.appName) on GitHub once a day, and offer to install it. Nothing is installed without your confirmation. You can always "
                    + "check by hand in the About window."
            ) {
                Toggle("", isOn: $updates.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .task { await notifications.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifications.refreshPermission() }
        }
    }

    private var notificationsDescription: Text {
        let text = Text("Show a system notification when a track starts and when the playlist ends, for when "
            + "\(AppConstants.appName) isn't in front.")
        guard notifications.isEnabled, notifications.isDeniedBySystem else { return text }
        return text + Text("\nNot working: notifications are turned off for \(AppConstants.appName) in System Settings "
            + "(Notifications).")
            .foregroundStyle(.red)
    }
}

private struct IntegrationsTab: View {
    private let lastFM = LastFMService.shared
    @Bindable private var lyrics = LyricsService.shared
    @State private var window: NSWindow?

    var body: some View {
        TabPage {
            PrefRow(title: "Last.fm", description: lastFMDescription) {
                Button(lastFM.isConnected ? "Disconnect..." : "Connect...") {
                    Task {
                        if lastFM.isConnected {
                            await LastFMActions.disconnect(on: window)
                        } else {
                            await LastFMActions.connect(on: window)
                        }
                    }
                }
                .disabled(!lastFM.isAvailable || lastFM.isAuthorizing)
            }

            PrefRow(title: "LRCLIB", description: lrclibDescription) {
                // Shows Off while lyrics support is off; the choice itself is kept for when it is turned on again.
                Toggle("", isOn: Binding(get: { lyrics.isLRCLIBActive }, set: { lyrics.isLRCLIBEnabled = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!lyrics.isEnabled)
            }
        }
        .background(WindowAccessor { window = $0 })
    }

    private var lrclibDescription: Text {
        let text = Text("Look up the lyrics of tracks that have none in their tags on lrclib.net (a free, community "
            + "driven database), when they start playing. Only tracks whose artist and title match exactly "
            + "are used. Lyrics that are found are saved locally and never replace the ones from the "
            + "tags. This sends the artist and title of the played tracks to lrclib.net.")
        guard !lyrics.isEnabled else { return text }
        return text + Text("\nNot working: Lyrics Support is turned off (General).")
            .foregroundStyle(.red)
    }

    private var lastFMDescription: Text {
        if let username = lastFM.username {
            var text = AttributedString("Connected as ")
            var name = AttributedString(username)
            name.link = LastFMAPI.profileURL(username: username)
            text += name
            text += AttributedString(". Tracks you play are sent to Last.fm as now playing and, once you've listened "
                + "to at least half of them, scrobbled.")
            return Text(text)
        }
        if !lastFM.isAvailable {
            return Text("Not available: this build has no Last.fm API credentials (see ICHM_LASTFM_* in .env).")
        }
        return Text("Send what you play to Last.fm: the track that plays now and the tracks you've listened to "
            + "(scrobbles). You'll be asked to allow \(AppConstants.appName) in your browser.")
    }
}

private struct HotkeysTab: View {
    @Bindable private var service = HotkeyService.shared

    var body: some View {
        TabPage {
            PrefRow(
                title: "React to Media Keys",
                description: "Control playback with the play/pause, next and previous media keys of your keyboard, "
                    + "headset or AirPods; the current track also shows up in Control Center. The system hands these "
                    + "keys to the app that played audio last, so before you play something they may go to another app."
            ) {
                Toggle("", isOn: $service.mediaKeys)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom Hotkeys")
                    .font(.body)
                Text("Global hotkeys, they work in any app. Click a field and press the keys: Esc cancels, Delete "
                    + "clears. Keys other than F-keys need a modifier (⌃ ⌥ ⇧ ⌘), and a combination can only be used "
                    + "once: setting it again moves it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(HotkeyAction.allCases) { action in
                        HotkeyRow(action: action, service: service)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct HotkeyRow: View {
    let action: HotkeyAction
    let service: HotkeyService

    var body: some View {
        HStack(spacing: 8) {
            Text(action.title)
                .frame(width: 110, alignment: .leading)
            HotkeyPicker(
                hotkey: service.hotkeys[action],
                onChange: { service.setHotkey($0, for: action) },
                onRecordingChange: { service.setRecording($0) }
            )
            .frame(width: 170, height: 22)
            if service.failed.contains(action) {
                Text("Already in use")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help("The system or another app already uses this combination.")
            }
        }
    }
}

private struct NowPlayingTab: View {
    @Bindable private var nowPlaying = NowPlayingSettings.shared

    var body: some View {
        TabPage {
            PrefRow(
                title: "Components",
                description: "Drag to reorder, or to move a component between the top part of the block and the bottom "
                    + "part, which stays at the bottom edge. Click the eye to show or hide one, the gear to change "
                    + "its options. Hidden album art isn't loaded.",
                accessory: {
                    Button("Reset Ordering & Visibility") { nowPlaying.resetLayout() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(nowPlaying.layout == .default)
                }
            ) {
                NowPlayingComponentList(settings: nowPlaying)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct EngineTab: View {
    @Bindable private var playback = PlaybackState.shared
    @Bindable private var store = PlaylistStore.shared
    /// Read when the tab appears: devices are only looked at when somebody needs to know.
    @State private var devices: [AudioOutputDevice] = []

    var body: some View {
        TabPage {
            PrefRow(
                title: "Output Device",
                description: "Where the sound goes. System Default follows the output chosen in System Settings. A "
                    + "device that isn't connected when playback starts is replaced by System Default."
            ) {
                Picker("", selection: $playback.outputDevice) {
                    Text("System Default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !playback.outputDevice.isEmpty, !devices.contains(where: { $0.uid == playback.outputDevice }) {
                        Text("Unavailable Device").tag(playback.outputDevice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
            }
            .onAppear { devices = AudioOutputDevices.all() }

            PrefRow(
                title: "Resample Quality",
                description: "Quality of the sample rate conversion, used for files whose sample rate differs from "
                    + "the one of the output device. High should be enough: Max costs about 25% more CPU in the "
                    + "converter for no audible gain. Applies to the tracks that start after the change."
            ) {
                Picker("", selection: $playback.resampleQuality) {
                    ForEach(ResampleQuality.allCases) { quality in
                        Text(quality.rawValue.capitalized).tag(quality)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            PrefRow(
                title: "Read-Ahead Buffer",
                description: "How much audio is decoded in advance, which is also the time the next track has to open "
                    + "without a gap. Longer values help with slow network shares and sleeping drives, and use a "
                    + "little more memory (about 46 MB for 60 s at 96 kHz)."
            ) {
                Picker("", selection: $playback.readAhead) {
                    ForEach(ConfigLimits.readAheadOptions, id: \.self) { seconds in
                        Text("\(seconds) s").tag(seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            PrefRow(
                title: "Tag Parsing Concurrency",
                description: "How many files are read at the same time when adding them to a playlist. Auto uses "
                    + "the number of physical CPU cores. Higher values can speed things up on network shares."
            ) {
                Picker("", selection: $store.tagParsingConcurrency) {
                    ForEach(ConfigLimits.tagParsingConcurrencyOptions, id: \.self) { count in
                        Text(count == ConfigLimits.tagParsingConcurrencyAuto ? "Auto" : String(count)).tag(count)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }
}

private struct UITab: View {
    @Bindable private var windowSettings = WindowSettings.shared

    var body: some View {
        TabPage {
            PrefRow(
                title: "Swap Playlist Selector with Now Playing",
                description: "Put the playlist selector and its toolbar button on the right side of the main window, "
                    + "and the now playing block and its button on the left."
            ) {
                Toggle("", isOn: $windowSettings.swapsSides)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}

private struct SearchTab: View {
    @Bindable private var settings = SearchSettings.shared
    private let queue = PlaybackState.shared.queue

    var body: some View {
        TabPage {
            PrefRow(
                title: "Search by Playlist Name",
                description: "Find playlists by their name (the whole name has to be typed) and list them in the search "
                    + "results. Turning this off removes playlists from the results."
            ) {
                Toggle("", isOn: $settings.byPlaylistName)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Search by Album Name",
                description: "Find albums by their artist and name and list them in the search results; tracks are also "
                    + "found by the name of their album. Turning this off removes albums from the results, and "
                    + "tracks are found only by their own artist and title."
            ) {
                Toggle("", isOn: $settings.byAlbumName)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Fuzzy Search",
                description: "Also find words typed with a typo (floid for Floyd) or with letters left out "
                    + "(pfloyd for Pink Floyd). Turning this off finds only what contains the typed words."
            ) {
                Toggle("", isOn: $settings.fuzzy)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PrefRow(
                title: "Prefer Adding to Queue",
                description: preferQueueDescription
            ) {
                // Shows Off while the queue is turned off; the choice itself is kept for when it is turned on again.
                Toggle("", isOn: Binding(get: { queue.isEnabled && settings.preferAddingToQueue },
                                         set: { settings.preferAddingToQueue = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!queue.isEnabled)
            }
        }
    }

    private var preferQueueDescription: Text {
        let text = Text("When enabled, ⏎ adds the result to the queue and ⇧⏎ plays it, instead of the other way round.")
        guard !queue.isEnabled else { return text }
        return text + Text("\nNot working: Enable Queue is turned off (General). Return plays, and ⇧⏎ does nothing.")
            .foregroundStyle(.red)
    }
}

private struct PlaylistTab: View {
    @Bindable private var settings = PlaylistSettings.shared
    /// Whose columns the list shows.
    @State private var columnsMode = PlaylistMode.album

    var body: some View {
        TabPage {
            PrefRow(
                title: "Album Header Style",
                description: "How the album blocks of playlists grouped by albums look: the album art with the "
                    + "artist, album and tags next to it (on the left or mirrored to the right), or a single line "
                    + "without the art. The art is still cached when adding files, so switching back to a style "
                    + "with it shows it right away."
            ) {
                Picker("", selection: $settings.albumHeaderStyle) {
                    ForEach(AlbumHeaderStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            PrefRow(
                title: "Playlist Entries Scale",
                description: "Changes the size of the track rows (their text and columns), between "
                    + "\(ConfigLimits.playlistEntriesScaleMin)% and \(ConfigLimits.playlistEntriesScaleMax)%. "
                    + "The album blocks keep their size.",
                accessory: {
                    Button("Reset to Default") { settings.entriesScale = ConfigLimits.playlistEntriesScaleDefault }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(settings.entriesScale == ConfigLimits.playlistEntriesScaleDefault)
                }
            ) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(settings.entriesScale) },
                                          set: { settings.entriesScale = Int($0.rounded()) }),
                           in: Double(ConfigLimits.playlistEntriesScaleMin)...Double(ConfigLimits.playlistEntriesScaleMax),
                           step: 1)
                    Text("\(settings.entriesScale)%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            PrefRow(
                title: "Columns",
                description: "The columns of the track rows of playlists grouped by albums (Album Mode) and of flat "
                    + "playlists (Flat Mode). Drag to reorder, click the eye to show or hide one. Details are the "
                    + "lyrics button and the codec.",
                accessory: {
                    Button("Reset Ordering & Visibility") { settings.resetColumns(columnsMode) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(settings[columns: columnsMode].isDefault)
                }
            ) {
                VStack(spacing: 8) {
                    Picker("", selection: $columnsMode) {
                        ForEach(PlaylistMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    PlaylistColumnList(settings: settings, mode: columnsMode)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
