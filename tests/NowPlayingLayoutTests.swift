// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor
    private final class CoverRecorder: NotificationDelivery {
        private(set) var covers: [Data?] = []
        func deliver(_ message: NotificationMessage, cover: Data?) { covers.append(cover) }
    }

    @MainActor @Suite("NowPlayingLayout")
    struct NowPlayingLayoutTests {
        private func decode(_ json: String) throws -> AppConfig {
            try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        }

        private func names(_ items: [NowPlayingItem]) -> [String] { items.map(\.component.rawValue) }

        @Test("the default layout: everything shown, the controls and the volume at the bottom")
        func defaults() {
            let layout = NowPlayingLayout.default
            #expect(names(layout.top) == ["album_art", "title", "subtitle", "duration", "seekbar", "details"])
            #expect(names(layout.bottom) == ["controls", "volume"])
            #expect(layout.top.allSatisfy(\.isVisible) && layout.bottom.allSatisfy(\.isVisible))
            #expect(layout.visibleTop.count == 6 && layout.visibleBottom.count == 2)
            #expect(AppConfig().nowPlaying.layout == layout)
            #expect(AppConfig().nowPlaying.enabled)
        }

        @Test("a layout built from outside is repaired: duplicates dropped, missing ones put back at their default end")
        func repair() {
            let layout = NowPlayingLayout(
                top: [NowPlayingItem(.volume), NowPlayingItem(.title, isVisible: false), NowPlayingItem(.volume)],
                bottom: [NowPlayingItem(.title), NowPlayingItem(.albumArt)])
            #expect(names(layout.top) == ["volume", "title", "subtitle", "duration", "seekbar", "details"])
            #expect(names(layout.bottom) == ["album_art", "controls"])
            #expect(layout.isVisible(.volume) && !layout.isVisible(.title))
            #expect(Set(layout.top.map(\.component) + layout.bottom.map(\.component)).count == 8)
        }

        @Test("toggling shows and hides a component, wherever it is")
        func toggle() {
            var layout = NowPlayingLayout.default
            layout.toggle(.albumArt)
            layout.toggle(.volume)
            #expect(!layout.isVisible(.albumArt) && !layout.isVisible(.volume))
            #expect(layout.visibleTop.first == .title)
            #expect(layout.visibleBottom == [.controls])
            layout.toggle(.albumArt)
            #expect(layout.isVisible(.albumArt))
        }

        @Test("moving takes a component to a slot, across the divider into the other stack")
        func move() {
            var layout = NowPlayingLayout.default
            // slots: 0 art, 1 title, 2 subtitle, 3 duration, 4 seekbar, 5 details, 6 divider, 7 controls, 8 volume
            #expect(layout.slots.count == 9 && layout.slots[6] == .divider)

            layout.move(from: 0, to: 2)
            #expect(names(layout.top) == ["title", "subtitle", "album_art", "duration", "seekbar", "details"])

            layout.move(from: 2, to: 7)                       // the art goes past the divider, to where slot 7 was
            #expect(names(layout.top) == ["title", "subtitle", "duration", "seekbar", "details"])
            #expect(names(layout.bottom) == ["controls", "album_art", "volume"])

            layout.move(from: 5, to: 0)                       // the divider can't be taken
            layout.move(from: 99, to: 0)
            layout.move(from: 0, to: 99)
            layout.move(from: 3, to: 3)
            #expect(names(layout.top) == ["title", "subtitle", "duration", "seekbar", "details"])
        }

        @Test("a stack can be emptied, and the other one filled")
        func emptyStack() {
            var layout = NowPlayingLayout.default
            layout.move(from: 7, to: 0)                       // the controls to the very top
            layout.move(from: 8, to: 0)                       // and the volume
            #expect(layout.bottom.isEmpty)
            #expect(names(layout.top).prefix(2) == ["volume", "controls"])
            #expect(layout.slots.last == .divider)

            var all = NowPlayingLayout.default
            for _ in 0..<6 { all.move(from: 0, to: 8) }       // the whole top stack, one by one, to the very end
            #expect(all.top.isEmpty)
            #expect(all.slots.first == .divider)
            #expect(all.bottom.count == 8)
        }

        @Test("the summary names what is hidden")
        func summary() {
            var layout = NowPlayingLayout.default
            layout.toggle(.title)
            #expect(layout.summary.contains("title (hidden)"))
            #expect(layout.summary.hasPrefix("top: album_art, title (hidden), subtitle"))
            #expect(layout.summary.hasSuffix("| bottom: controls, volume"))
        }

        // MARK: Config

        @Test("the config reads and writes the lists as `top` and `bottom`")
        func configRoundTrip() throws {
            let config = try decode("""
            {"now_playing": {"enabled": false,
                             "top": [{"id": "volume", "visible": true}, {"id": "album_art", "visible": false}],
                             "bottom": [{"id": "seekbar"}]}}
            """)
            #expect(!config.nowPlaying.enabled)
            #expect(names(config.nowPlaying.layout.top).prefix(2) == ["volume", "album_art"])
            #expect(!config.nowPlaying.layout.isVisible(.albumArt))
            #expect(names(config.nowPlaying.layout.bottom).first == "seekbar")
            #expect(config.nowPlaying.layout.isVisible(.seekbar))        // "visible" is optional, on by default

            let data = try JSONEncoder().encode(config)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains(#""enabled":false"#))
            #expect(text.contains(#""id":"album_art""#) && text.contains(#""visible":false"#))
            #expect(try decode(text) == config)
        }

        @Test("what can't be read in the lists is left out, and the layout repaired; nothing else is reset")
        func configLenient() throws {
            let config = try decode("""
            {"now_playing": {"component_options": {"seekbar_style": "spectrogram"},
                             "top": [{"id": "lyrics", "visible": true}, {"id": "subtitle"}, "nonsense", {"id": 5},
                                     {"id": "title", "visible": "yes"}, {"id": "track"}],
                             "bottom": "not a list"}}
            """)
            #expect(config.nowPlaying.componentOptions.seekbarStyle == .spectrogram)
            #expect(config.nowPlaying.enabled)
            #expect(names(config.nowPlaying.layout.top).prefix(2) == ["subtitle", "title"])
            #expect(config.nowPlaying.layout.isVisible(.title))          // a visible flag that isn't one counts as on
            #expect(Set(config.nowPlaying.layout.top.map(\.component) + config.nowPlaying.layout.bottom.map(\.component)).count == 8)

            #expect(try decode(#"{"now_playing": {"top": 3}}"#).nowPlaying.layout == .default)
            #expect(try decode(#"{"now_playing": {"enabled": "no"}}"#).nowPlaying.enabled)
        }

        @Test("the texts of Title and Subtitle are in `component_options`, default, read leniently and reset when too long")
        func configTexts() throws {
            let defaults = AppConfig().nowPlaying.componentOptions
            #expect(defaults.title == "{artist} – {title}" && defaults.subtitle == "{album} ({year})")

            let config = try decode("""
            {"now_playing": {"component_options": {"title": "{title}", "subtitle": 5}}}
            """)
            #expect(config.nowPlaying.componentOptions.title == "{title}")
            #expect(config.nowPlaying.componentOptions.subtitle == defaults.subtitle)
            #expect(try decode("{\"now_playing\": {\"component_options\": 3}}").nowPlaying.componentOptions == defaults)

            let text = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
            #expect(text.contains(#""title":"{title}""#) && text.contains(#""subtitle":"{album} ({year})""#))
            #expect(try decode(text) == config)

            var long = config
            long.nowPlaying.componentOptions.title = String(repeating: "x", count: ConfigLimits.componentTextMaxLength + 1)
            long.nowPlaying.componentOptions.subtitle = String(repeating: "y", count: ConfigLimits.componentTextMaxLength)
            let validated = long.validated().nowPlaying.componentOptions
            #expect(validated.title == defaults.title)
            #expect(validated.subtitle == long.nowPlaying.componentOptions.subtitle)
        }

        @Test("variables are replaced, `\\{` is a literal brace, unknown names are left as written")
        func templateSyntax() {
            let values: [TemplateVariable: String] = [.artist: "A", .title: "T", .album: "Al", .year: "1999", .track: "7"]
            func render(_ template: String) -> String { TextTemplate.render(template, values: values) }
            #expect(render("{artist} – {title}") == "A – T")
            #expect(render("{album} ({year})") == "Al (1999)")
            #expect(render("{track}. {Title}{title}") == "7. TT")
            #expect(render("\\{artist} is {artist}") == "{artist} is A")
            #expect(render("\\{artist}") == "{artist}")
            #expect(render("{nonsense} { {year} } {year") == "{nonsense} { 1999 } {year")
            #expect(render("back\\slash {}") == "back\\slash {}")
            #expect(render("") == "")
        }

        @Test("a missing value is empty, and the brackets around it go with it")
        func templateMissingValues() {
            let noYear: [TemplateVariable: String] = [.artist: "A", .title: "T", .album: "Al"]
            #expect(TextTemplate.render("{album} ({year})", values: noYear) == "Al")
            #expect(TextTemplate.render("{album} [{year}] {artist}", values: noYear) == "Al A")
            #expect(TextTemplate.render("{year}", values: noYear) == "")
            #expect(TextTemplate.render("{track} {title}", values: noYear) == "T")
            // Nothing is missing: the template is used as written.
            var complete = noYear
            complete[.year] = "1"
            #expect(TextTemplate.render("{title}  ()", values: complete) == "T  ()")
        }

        @Test("the track info offers every variable")
        func templateValues() {
            let info = PlaybackState.TrackInfo(artist: "A", title: "T", album: "Al", year: nil, number: 3, codec: "FLAC")
            #expect(info.templateValues == [.artist: "A", .title: "T", .album: "Al", .year: "", .track: "3"])
            #expect(Set(info.templateValues.keys) == Set(TemplateVariable.allCases))
            #expect(TemplateVariable.allCases.map(\.token) == ["{artist}", "{title}", "{album}", "{year}", "{track}"])
        }

        // MARK: Settings

        @Test("the settings keep the layout and the switch in the config and tell the observers")
        func settings() throws {
            let dir = try TempDir()
            let config = ConfigStore(paths: AppPaths(workDir: dir.path("work")), saveDelay: .seconds(60))
            let settings = NowPlayingSettings(configStore: config)
            #expect(settings.isEnabled && settings.showsArt && settings.showsSeekbar && !settings.needsWaveform)
            var calls = 0
            settings.addVisibilityObserver { calls += 1 }

            settings.layout.toggle(.albumArt)
            #expect(calls == 1 && !settings.showsArt)
            #expect(!config.config.nowPlaying.layout.isVisible(.albumArt))
            settings.layout.toggle(.albumArt)
            settings.isEnabled = false
            settings.isEnabled = false
            #expect(calls == 3)
            #expect(!settings.showsArt && !settings.showsSeekbar)
            #expect(!config.config.nowPlaying.enabled)

            let restarted = NowPlayingSettings(configStore: config)
            #expect(!restarted.isEnabled)
            restarted.isEnabled = true
            restarted.layout.move(from: 0, to: 8)
            #expect(restarted.layout != .default)
            #expect(NowPlayingSettings(configStore: config).layout == restarted.layout)
            restarted.resetLayout()
            #expect(NowPlayingSettings(configStore: config).layout == .default)
            #expect(NowPlayingSettings().isEnabled)
        }

        @Test("the waveform is wanted for a visual style only while the seek bar is on screen")
        func needsWaveform() {
            let settings = NowPlayingSettings()
            settings.style = .waveformRMS
            #expect(settings.needsWaveform)
            settings.layout.toggle(.seekbar)
            #expect(!settings.needsWaveform)
            settings.layout.toggle(.seekbar)
            settings.isEnabled = false
            #expect(!settings.needsWaveform)
            settings.isEnabled = true
            #expect(settings.needsWaveform)
            settings.style = .standard
            #expect(!settings.needsWaveform)
        }

        @Test("the texts of Title and Subtitle are kept in the config, and resetting the layout leaves them alone")
        func templateSettings() throws {
            let dir = try TempDir()
            let config = ConfigStore(paths: AppPaths(workDir: dir.path("work")), saveDelay: .seconds(60))
            let settings = NowPlayingSettings(configStore: config)
            #expect(settings.titleTemplate == "{artist} – {title}" && settings.subtitleTemplate == "{album} ({year})")

            settings.titleTemplate = "{track}. {title}"
            settings.subtitleTemplate = "{album}"
            settings.resetLayout()
            #expect(config.config.nowPlaying.componentOptions.title == "{track}. {title}")
            #expect(config.config.nowPlaying.componentOptions.subtitle == "{album}")
            let restarted = NowPlayingSettings(configStore: config)
            #expect(restarted.titleTemplate == "{track}. {title}" && restarted.subtitleTemplate == "{album}")
        }

        // MARK: Playback controls

        private func controlNames(_ layout: PlaybackControlsLayout) -> [String] { layout.items.map(\.control.rawValue) }

        @Test("the controls: the random buttons are there but hidden by default, the others are shown")
        func controlDefaults() {
            let layout = PlaybackControlsLayout.default
            #expect(controlNames(layout) == ["previous_album", "previous_track", "play_pause", "next_track", "next_album",
                                             "stop", "random_track", "random_album"])
            #expect(layout.visible == [.previousAlbum, .previousTrack, .playPause, .nextTrack, .nextAlbum, .stop])
            #expect(!layout.isVisible(.randomTrack) && !layout.isVisible(.randomAlbum))
            #expect(AppConfig().nowPlaying.componentOptions.controls == layout)
        }

        @Test("the controls are repaired: no button twice, a missing one is added at the end as it is by default")
        func controlRepair() {
            let layout = PlaybackControlsLayout(items: [PlaybackControlItem(.stop), PlaybackControlItem(.randomAlbum),
                                                        PlaybackControlItem(.stop, isVisible: false)])
            #expect(controlNames(layout) == ["stop", "random_album", "previous_album", "previous_track", "play_pause",
                                             "next_track", "next_album", "random_track"])
            #expect(layout.isVisible(.stop) && !layout.isVisible(.randomAlbum))   // the first `stop` counts
            #expect(layout.isVisible(.previousAlbum) && !layout.isVisible(.randomTrack))
        }

        @Test("the controls can be shown, hidden and moved")
        func controlChanges() {
            var layout = PlaybackControlsLayout.default
            layout.toggle(.randomTrack)
            layout.toggle(.stop)
            #expect(layout.visible == [.previousAlbum, .previousTrack, .playPause, .nextTrack, .nextAlbum, .randomTrack])
            #expect(layout.isVisible(.randomTrack) && !layout.isVisible(.stop))

            layout.move(from: 6, to: 0)
            #expect(controlNames(layout).prefix(3) == ["random_track", "previous_album", "previous_track"])
            layout.move(from: 0, to: 7)
            #expect(controlNames(layout).last == "random_track")
            let before = layout
            layout.move(from: 3, to: 3)
            layout.move(from: -1, to: 2)
            layout.move(from: 2, to: 8)
            #expect(layout == before)
            #expect(layout.summary.contains("stop (hidden)") && !layout.summary.contains("random_track (hidden)"))
        }

        @Test("the controls are read from `component_options.controls`; what can't be read is repaired")
        func controlConfig() throws {
            #expect(try decode("{}").nowPlaying.componentOptions.controls == .default)
            #expect(try decode(#"{"now_playing": {"component_options": {"controls": 5}}}"#)
                .nowPlaying.componentOptions.controls == .default)

            let json = #"""
            {"now_playing": {"component_options": {"controls": [
                {"id": "random_album", "visible": true}, {"id": "nonsense"}, 7, {"id": "stop", "visible": false},
                {"id": "random_album", "visible": false}, {"id": "play_pause"}]}}}
            """#
            let layout = try decode(json).nowPlaying.componentOptions.controls
            #expect(controlNames(layout).prefix(3) == ["random_album", "stop", "play_pause"])
            #expect(layout.isVisible(.randomAlbum) && !layout.isVisible(.stop) && layout.isVisible(.playPause))
            #expect(controlNames(layout).count == PlaybackControl.allCases.count)

            var config = AppConfig()
            config.nowPlaying.componentOptions.controls = layout
            let data = try JSONEncoder().encode(config)
            #expect(try JSONDecoder().decode(AppConfig.self, from: data).nowPlaying.componentOptions.controls == layout)
        }

        @Test("the settings keep the controls in the config, and resetting them leaves the rest alone")
        func controlSettings() throws {
            let dir = try TempDir()
            let config = ConfigStore(paths: AppPaths(workDir: dir.path("work")), saveDelay: .seconds(60))
            let settings = NowPlayingSettings(configStore: config)
            #expect(settings.controls == .default)

            settings.controls.toggle(.randomTrack)
            settings.controls.move(from: 0, to: 4)
            settings.titleTemplate = "{title}"
            #expect(config.config.nowPlaying.componentOptions.controls == settings.controls)
            #expect(NowPlayingSettings(configStore: config).controls == settings.controls)

            settings.resetControls()
            #expect(config.config.nowPlaying.componentOptions.controls == .default)
            #expect(config.config.nowPlaying.componentOptions.title == "{title}")
        }

        // MARK: Album art

        @Test("no cover goes with the notification while the art is hidden")
        func notificationCover() throws {
            let dir = try TempDir()
            let covers = CoverStore(url: dir.path("covers.sqlite"), thumbnailPixels: 112)
            let image = Data([0xFF, 0xD8, 0xFF, 0xE0])
            covers.store(image, for: "key")
            var track = LastFMTestData.track()
            track.coverKey = "key"

            let delivery = CoverRecorder()
            let settings = NowPlayingSettings()
            let service = NotificationService(delivery: delivery, coverStore: covers, nowPlaying: settings)

            service.trackDidStart(track)
            settings.layout.toggle(.albumArt)
            service.trackDidStart(track)
            settings.layout.toggle(.albumArt)
            settings.isEnabled = false
            service.trackDidStart(track)
            #expect(delivery.covers == [image, nil, nil])
        }

        @Test("the art of the playing album is only loaded while it is shown, and let go of when it is hidden")
        func artLoading() async throws {
            let dir = try TempDir()
            let file = try dir.copy("formats/t_cover.flac", to: "01.flac")
            let entry = Make.entry(file.path, artist: "A", album: "Album", title: "T", track: 1)

            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            let store = PlaylistStore(paths: paths, configStore: config)
            #expect(await waitUntil { !store.isLoading })
            await store.append(Make.albums([entry]), to: "main")
            let settings = NowPlayingSettings()
            settings.layout.toggle(.albumArt)
            let state = PlaybackState(store: store, engine: EngineRig(lookahead: 60).engine, tickInterval: nil,
                                      nowPlaying: settings)

            state.play(albumIndex: 0, trackIndex: 0)
            #expect(state.info?.title == "T")
            #expect(state.artwork == nil && !state.isLoadingArtwork)       // not even looked up
            try await Task.sleep(for: .milliseconds(200))
            #expect(state.artwork == nil && !state.isLoadingArtwork)

            settings.layout.toggle(.albumArt)                              // shown: loaded for what plays now
            #expect(await waitUntil { state.artwork != nil })
            #expect(!state.isLoadingArtwork)

            settings.isEnabled = false                                     // the block goes away: so does the art
            #expect(state.artwork == nil && !state.isLoadingArtwork)
            settings.isEnabled = true
            #expect(await waitUntil { state.artwork != nil })
            state.stop()
        }
    }
}
