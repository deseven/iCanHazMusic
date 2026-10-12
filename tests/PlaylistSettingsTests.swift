// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Playlist settings")
    struct PlaylistSettingsTests {
        private func decode(_ json: String) throws -> AppConfig {
            try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        }

        private func names(_ layout: PlaylistColumnsLayout) -> [String] { layout.items.map(\.column.rawValue) }

        @Test("the default columns: all of them in both modes, the track number hidden in flat mode")
        func defaults() {
            let album = PlaylistColumnsLayout.default(.album)
            let flat = PlaylistColumnsLayout.default(.flat)
            #expect(names(album) == ["status", "number", "title", "duration", "details"])
            #expect(names(flat) == names(album))
            #expect(album.visible == [.status, .number, .title, .duration, .details])
            #expect(flat.visible == [.status, .title, .duration, .details])
            #expect(album.isDefault && flat.isDefault)
            #expect(album != flat)

            let config = AppConfig().playlist
            #expect(config.albumHeaderStyle == .albumArt)
            #expect(config.entriesScale == 100)
            #expect(config.albumColumns == album && config.flatColumns == flat)
        }

        @Test("the columns are repaired: no column twice, a missing one is added at the end as it is by default")
        func repair() {
            let layout = PlaylistColumnsLayout(mode: .flat, items: [
                PlaylistColumnItem(.title, isVisible: false), PlaylistColumnItem(.duration, isVisible: true),
                PlaylistColumnItem(.title, isVisible: true),
            ])
            #expect(names(layout) == ["title", "duration", "status", "number", "details"])
            #expect(!layout.isVisible(.title))   // the first `title` counts
            #expect(layout.isVisible(.status) && !layout.isVisible(.number) && layout.isVisible(.details))
            #expect(PlaylistColumnsLayout(mode: .album, items: []).isVisible(.number))
        }

        @Test("the columns can be shown, hidden and moved")
        func changes() {
            var layout = PlaylistColumnsLayout.default(.album)
            layout.toggle(.number)
            #expect(layout.visible == [.status, .title, .duration, .details])
            #expect(!layout.isDefault)
            layout.toggle(.number)
            #expect(layout.isDefault)

            layout.move(from: 4, to: 0)
            #expect(names(layout) == ["details", "status", "number", "title", "duration"])
            let before = layout
            layout.move(from: 2, to: 2)
            layout.move(from: -1, to: 2)
            layout.move(from: 1, to: 5)
            #expect(layout == before)
            layout.toggle(.status)
            #expect(layout.summary == "details, status (hidden), number, title, duration")
        }

        @Test("the playlist section is read leniently; what can't be read is repaired")
        func config() throws {
            let config = try decode("""
            {"playlist": {"album_header_style": "album_art_right", "entries_scale": 150,
              "album_columns": [{"id": "title", "visible": true}, {"id": "status", "visible": false}],
              "flat_columns": [{"id": "number", "visible": true}, {"id": "nope", "visible": true}, {"id": "title"}, 7]}}
            """)
            #expect(config.playlist.albumHeaderStyle == .albumArtRight)
            #expect(config.playlist.entriesScale == 150)
            #expect(names(config.playlist.albumColumns) == ["title", "status", "number", "duration", "details"])
            #expect(config.playlist.albumColumns.visible == [.title, .number, .duration, .details])
            // Entries without a known id or a visibility are left out, then added back at the end.
            #expect(names(config.playlist.flatColumns) == ["number", "status", "title", "duration", "details"])
            #expect(config.playlist.flatColumns.visible == [.number, .status, .title, .duration, .details])

            let invalid = try decode("""
            {"playlist": {"album_header_style": true, "entries_scale": "big", "album_columns": 5, "flat_columns": {}}}
            """)
            #expect(invalid.playlist == AppConfig().playlist)
        }

        @Test("the columns are written as lists of id and visibility and read back the same")
        func roundTrip() throws {
            var config = AppConfig()
            config.playlist.flatColumns.toggle(.number)
            config.playlist.albumColumns.move(from: 0, to: 4)
            config.playlist.entriesScale = 70
            let data = try JSONEncoder().encode(config)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let playlist = try #require(object?["playlist"] as? [String: Any])
            let flat = try #require(playlist["flat_columns"] as? [[String: Any]])
            #expect(flat.count == PlaylistColumn.allCases.count)
            #expect(flat[1]["id"] as? String == "number" && flat[1]["visible"] as? Bool == true)
            #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)
        }

        @Test("a scale outside of the limits is reset", arguments: [0, 69, 201, 1000])
        func invalidScale(scale: Int) {
            var config = AppConfig()
            config.playlist.entriesScale = scale
            config.playlist.albumHeaderStyle = .noAlbumArt
            let result = config.validated()
            #expect(result.playlist.entriesScale == ConfigLimits.playlistEntriesScaleDefault)
            #expect(result.playlist.albumHeaderStyle == .noAlbumArt)
        }

        @Test("the scale limits are valid")
        func validScale() {
            for scale in [ConfigLimits.playlistEntriesScaleMin, 100, ConfigLimits.playlistEntriesScaleMax] {
                var config = AppConfig()
                config.playlist.entriesScale = scale
                #expect(config.validated() == config)
            }
        }

        @Test("the settings are read from the config and written back when changed; a reset touches one mode only")
        func settings() throws {
            let dir = try TempDir()
            let config = ConfigStore(paths: AppPaths(workDir: dir.path("work")), saveDelay: .seconds(60))
            let settings = PlaylistSettings(configStore: config)
            #expect(settings.albumHeaderStyle == .albumArt && settings.entriesScale == 100)
            #expect(settings[columns: .album] == .default(.album) && settings[columns: .flat] == .default(.flat))

            settings.albumHeaderStyle = .noAlbumArt
            settings.entriesScale = 130
            settings[columns: .album].toggle(.details)
            settings[columns: .flat].move(from: 0, to: 2)
            #expect(config.config.playlist.albumHeaderStyle == .noAlbumArt)
            #expect(config.config.playlist.entriesScale == 130)
            #expect(!config.config.playlist.albumColumns.isVisible(.details))
            #expect(names(config.config.playlist.flatColumns).prefix(3) == ["number", "title", "status"])

            let restarted = PlaylistSettings(configStore: config)
            #expect(restarted.albumHeaderStyle == .noAlbumArt && restarted.entriesScale == 130)
            #expect(restarted.albumColumns == settings.albumColumns && restarted.flatColumns == settings.flatColumns)

            settings.resetColumns(.flat)
            #expect(config.config.playlist.flatColumns == .default(.flat))
            #expect(!config.config.playlist.albumColumns.isVisible(.details))
        }

        @Test("track rows: the row height follows the scale in whole points, the layout uses it")
        func rowStyle() {
            #expect(TrackRowStyle.standard.rowHeight == Layout.trackRowHeight)
            #expect(TrackRowStyle(scale: 200).rowHeight == 2 * Layout.trackRowHeight)
            let small = TrackRowStyle(scale: 73)
            #expect(small.rowHeight == small.rowHeight.rounded())
            #expect(TrackRowStyle(scale: 150).durationWidth > TrackRowStyle.standard.durationWidth)
            #expect(TrackRowStyle.standard.columns(isFlat: true) == [.status, .title, .duration, .details])
            #expect(TrackRowStyle.standard.showsAlbumArt && TrackRowStyle(headerStyle: .albumArtRight).showsAlbumArt)
            #expect(!TrackRowStyle(headerStyle: .noAlbumArt).showsAlbumArt)

            let p = Make.playlist(Make.entries(dir: "A", album: "A", count: 2))
            let header = Layout.albumHeaderRowHeight
            #expect(PlaylistLayout(playlist: p, showAlbumArt: true, trackHeight: 30).rowOffsets
                    == [0, header, header + 30, header + 60])
        }
    }
}
