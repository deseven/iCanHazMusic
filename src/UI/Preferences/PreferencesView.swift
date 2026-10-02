import SwiftUI

/// Preferences window with vertical tabs. Opened from the app menu (⌘,).
/// Every control writes straight through to the setting's owner (`PlaybackState`, `PlaylistStore`), which
/// applies it and keeps it in the config.
struct PreferencesView: View {
    @State private var selectedTab: Tab = .general

    private enum Tab: String, CaseIterable, Identifiable {
        case general
        case playback
        case playlist
        case integrations
        case hotkeys

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: "General"
            case .playback: "Playback"
            case .playlist: "Playlist"
            case .integrations: "Integrations"
            case .hotkeys: "Hotkeys"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .playback: "play.circle"
            case .playlist: "music.note.list"
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
                case .playback: PlaybackTab()
                case .playlist: PlaylistTab()
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
private struct PrefRow<Control: View>: View {
    let title: String
    let description: Text
    @ViewBuilder let control: () -> Control

    init(title: String, description: String, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, description: Text(description), control: control)
    }

    /// For descriptions with more than plain text (a link).
    init(title: String, description: Text, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.description = description
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body)
            control()
            description
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

/// A tab without settings yet.
private struct EmptyTab: View {
    var body: some View {
        TabPage {
            Text("Nothing here yet.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tabs

private struct GeneralTab: View {
    var body: some View { EmptyTab() }
}

private struct IntegrationsTab: View {
    private let lastFM = LastFMService.shared
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
        }
        .background(WindowAccessor { window = $0 })
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
    var body: some View { EmptyTab() }
}

private struct PlaybackTab: View {
    @Bindable private var playback = PlaybackState.shared

    var body: some View {
        TabPage {
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
        }
    }
}

private struct PlaylistTab: View {
    @Bindable private var store = PlaylistStore.shared

    var body: some View {
        TabPage {
            PrefRow(
                title: "Tag Parsing Concurrency",
                description: "How many files are read at the same time when adding them to a playlist. Auto uses "
                    + "half of the physical CPU cores. Higher values can speed things up on network shares."
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

            PrefRow(
                title: "Display Album Art",
                description: "Show the album art in the album blocks of playlists grouped by albums. The art is "
                    + "still cached when adding files, so turning this back on shows it right away."
            ) {
                Toggle("", isOn: $store.displayAlbumArt)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}
