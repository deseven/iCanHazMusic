import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Track")
    struct TrackTests {
        private func track(number: Int?, duration: TimeInterval?) -> Track {
            Track(url: URL(fileURLWithPath: "/a.mp3"), number: number, title: "t", artist: "a", duration: duration, codec: "MP3")
        }

        @Test("duration text")
        func durationText() {
            #expect(track(number: nil, duration: nil).durationText == "--:--")
            #expect(track(number: nil, duration: 0).durationText == "00:00")
            #expect(track(number: nil, duration: 65.9).durationText == "01:05")
            #expect(track(number: nil, duration: 3599).durationText == "59:59")
            #expect(track(number: nil, duration: 3600).durationText == "60:00")
        }

        @Test("number text")
        func numberText() {
            #expect(track(number: nil, duration: nil).numberText == "")
            #expect(track(number: 3, duration: nil).numberText == "03")
            #expect(track(number: 12, duration: nil).numberText == "12")
            #expect(track(number: 123, duration: nil).numberText == "123")
        }
    }

    @MainActor @Suite("AlbumBuilder")
    struct AlbumBuilderTests {
        @Test("no entries, no albums")
        func empty() {
            #expect(AlbumBuilder.build(from: [TrackEntry]()).isEmpty)
        }

        @Test("files of one album and directory form one block, in input order")
        func oneAlbum() {
            let albums = AlbumBuilder.build(from: [
                Make.entry("/M/A/02.mp3", album: "X", track: 2),
                Make.entry("/M/A/01.mp3", album: "X", track: 1),
            ])
            #expect(albums.count == 1)
            #expect(albums[0].tracks.map(\.number) == [2, 1])
            #expect(albums[0].title == "X")
            #expect(albums[0].directory.path == "/M/A")
            #expect(albums[0].artist == "Artist")
            #expect(!albums[0].hasMultipleArtists)
        }

        @Test("album titles match case-insensitively")
        func caseInsensitive() {
            let albums = AlbumBuilder.build(from: [
                Make.entry("/M/A/1.mp3", album: "Dark Side"),
                Make.entry("/M/A/2.mp3", album: "DARK SIDE"),
            ])
            #expect(albums.count == 1)
            #expect(albums[0].title == "Dark Side")      // the first spelling wins
        }

        @Test("the same album name in two directories gives two blocks")
        func twoDirectories() {
            let albums = AlbumBuilder.build(from: [
                Make.entry("/M/CD1/1.mp3", album: "Best Of"),
                Make.entry("/M/CD2/1.mp3", album: "Best Of"),
            ])
            #expect(albums.count == 2)
        }

        @Test("two albums in one directory give two blocks")
        func twoAlbumsOneDirectory() {
            let albums = AlbumBuilder.build(from: [
                Make.entry("/M/Mixed/1.mp3", album: "One"),
                Make.entry("/M/Mixed/2.mp3", album: "Two"),
                Make.entry("/M/Mixed/3.mp3", album: "One"),
            ])
            #expect(albums.map(\.title) == ["One", "Two"])
            #expect(albums[0].tracks.map(\.url.lastPathComponent) == ["1.mp3", "3.mp3"])
        }

        @Test("blocks are ordered by their first file")
        func blockOrder() {
            let albums = AlbumBuilder.build(from: [
                Make.entry("/M/B/1.mp3", album: "B"),
                Make.entry("/M/A/1.mp3", album: "A"),
                Make.entry("/M/B/2.mp3", album: "B"),
            ])
            #expect(albums.map(\.title) == ["B", "A"])
        }

        @Test("different artists make a Various Artists album")
        func variousArtists() {
            let albums = AlbumBuilder.build(from: [
                Make.entry("/M/V/1.mp3", artist: "One", album: "Comp"),
                Make.entry("/M/V/2.mp3", artist: "Two", album: "Comp"),
            ])
            #expect(albums[0].artist == AlbumBuilder.variousArtists)
            #expect(albums[0].hasMultipleArtists)
            #expect(albums[0].tracks.map(\.artist) == ["One", "Two"])
        }

        @Test("the year is the first one that is known")
        func year() {
            let albums = AlbumBuilder.build(from: [
                Make.entry("/M/A/1.mp3", year: nil),
                Make.entry("/M/A/2.mp3", year: "1999"),
                Make.entry("/M/A/3.mp3", year: "2005"),
            ])
            #expect(albums[0].year == "1999")
            #expect(AlbumBuilder.build(from: [Make.entry("/M/A/1.mp3")])[0].year == nil)
        }

        @Test("tracks keep their details")
        func trackDetails() {
            let albums = AlbumBuilder.build(from: [Make.entry("/M/A/01 Song.flac", title: "Song", track: 1, duration: 12.5)])
            let track = albums[0].tracks[0]
            #expect(track.title == "Song")
            #expect(track.number == 1)
            #expect(track.duration == 12.5)
            #expect(track.codec == "FLAC")
            #expect(track.url.path == "/M/A/01 Song.flac")
        }

        @Test("only complete and partial tag reads are usable")
        func usable() {
            #expect(AlbumBuilder.isUsable(.complete))
            #expect(AlbumBuilder.isUsable(.partial(fallbacks: ["artist"])))
            #expect(!AlbumBuilder.isUsable(.noTags))
            #expect(!AlbumBuilder.isUsable(.failed("x")))
        }

        @Test("tag results: unusable ones are skipped")
        func fromResults() {
            let albums = AlbumBuilder.build(from: [
                Make.result("/M/A/1.mp3", id: 0),
                Make.result("/M/A/2.mp3", id: 1, status: .failed("bad")),
                Make.result("/M/A/3.mp3", id: 2, status: .noTags),
                Make.result("/M/A/4.mp3", id: 3, status: .partial(fallbacks: ["artist"])),
            ])
            #expect(albums.count == 1)
            #expect(albums[0].tracks.map(\.url.lastPathComponent) == ["1.mp3", "4.mp3"])
        }

        @Test("the album key is directory and lowercased title")
        func albumKey() {
            let a = Make.albums([Make.entry("/M/A/1.mp3", album: "Some Album")])[0]
            #expect(a.key == AlbumKey.make(directory: URL(fileURLWithPath: "/M/A"), title: "some album"))
            #expect(a.key == "/M/A\u{1F}some album")
            #expect(AlbumKey.make(directory: URL(fileURLWithPath: "/M/B"), title: "x") != AlbumKey.make(directory: URL(fileURLWithPath: "/M/A"), title: "x"))
        }
    }

    @MainActor @Suite("TrackEntry")
    struct TrackEntryTests {
        private func decode(_ json: String) throws -> TrackEntry {
            try JSONDecoder().decode(TrackEntry.self, from: Data(json.utf8))
        }

        @Test("only the path is required, the rest falls back")
        func lenient() throws {
            let e = try decode(#"{"path": "/Music/Artist/Album/01 Song.flac"}"#)
            #expect(e.path == "/Music/Artist/Album/01 Song.flac")
            #expect(e.title == "01 Song")
            #expect(e.artist == TagFallback.artist)
            #expect(e.album == TagFallback.album)
            #expect(e.codec == "FLAC")
            #expect(e.trackNumber == nil)
            #expect(e.year == nil)
            #expect(e.duration == nil)
        }

        @Test("a missing or empty path is an error")
        func pathRequired() {
            #expect(throws: (any Error).self) { try decode(#"{"artist": "A"}"#) }
            #expect(throws: (any Error).self) { try decode(#"{"path": ""}"#) }
            #expect(throws: (any Error).self) { try decode(#"{"path": 5}"#) }
        }

        @Test("values of the wrong type are replaced by the fallbacks")
        func wrongTypes() throws {
            let e = try decode(#"{"path": "/a/b.mp3", "artist": 5, "album": "", "title": null, "trackNumber": "x", "year": 2019, "duration": "long"}"#)
            #expect(e.artist == TagFallback.artist)
            #expect(e.album == TagFallback.album)
            #expect(e.title == "b")
            #expect(e.trackNumber == nil)
            #expect(e.year == nil)
            #expect(e.duration == nil)
        }

        @Test("full entry round-trips; unknown values are omitted from the file")
        func roundTrip() throws {
            let full = Make.entry("/M/A/1.mp3", artist: "Ar", album: "Al", title: "Ti", track: 4, year: "1999", duration: 61.5)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(full)
            let decoded = try JSONDecoder().decode(TrackEntry.self, from: data)
            #expect(decoded.path == full.path)
            #expect(decoded.artist == "Ar")
            #expect(decoded.album == "Al")
            #expect(decoded.title == "Ti")
            #expect(decoded.trackNumber == 4)
            #expect(decoded.year == "1999")
            #expect(decoded.duration == 61.5)
            #expect(decoded.codec == "MP3")

            let sparse = try String(decoding: encoder.encode(Make.entry("/M/A/1.mp3")), as: UTF8.self)
            #expect(!sparse.contains("trackNumber"))
            #expect(!sparse.contains("year"))
            #expect(!sparse.contains("duration"))
        }

        @Test("from a tag result: the title falls back to the file name, the codec is the upper-cased extension")
        func fromResult() {
            let tagged = TrackEntry(result: Make.result("/M/A/01 whatever.ogg", title: "Real Title"))
            #expect(tagged.title == "Real Title")
            #expect(tagged.codec == "OGG")

            let untitled = TrackEntry(result: Make.result("/M/A/01 whatever.Flac", title: nil))
            #expect(untitled.title == "01 whatever")
            #expect(untitled.codec == "FLAC")
        }

        @Test("from an album track, with the album's title and year")
        func fromAlbum() {
            let album = Make.albums([Make.entry("/M/A/1.mp3", artist: "Ar", album: "Al", title: "Ti", track: 1, year: "2001", duration: 9)])[0]
            let entry = TrackEntry(album: album, track: album.tracks[0])
            #expect(entry.album == "Al")
            #expect(entry.year == "2001")
            #expect(entry.title == "Ti")
            #expect(entry.artist == "Ar")
            #expect(entry.path == "/M/A/1.mp3")
            #expect(entry.duration == 9)
        }
    }

    @MainActor @Suite("Playlist")
    struct PlaylistTests {
        /// Rows: 0 header A, 1-2 tracks, 3 header B, 4 track.
        private var playlist: Playlist {
            Make.playlist(Make.entries(dir: "A", album: "A", count: 2) + Make.entries(dir: "B", album: "B", count: 1))
        }

        @Test("flattens albums into header and track rows")
        func rows() {
            let p = playlist
            #expect(p.rows.count == 5)
            #expect(p.rows.map(\.isHeader) == [true, false, false, true, false])
            #expect(p.rows.map(\.albumIndex) == [0, 0, 0, 1, 1])
            #expect(p.rows.enumerated().allSatisfy { $0.offset == $0.element.id })
            #expect(p.headerRow == [0, 3])
            #expect(p.trackRows == [1..<3, 4..<5])
            #expect(p.trackCount == 3)
        }

        @Test("the empty playlist")
        func empty() {
            #expect(Playlist.empty.rows.isEmpty)
            #expect(Playlist.empty.trackCount == 0)
            #expect(Playlist.empty.entries.isEmpty)
        }

        @Test("tracks of rows")
        func trackForRow() {
            let p = playlist
            #expect(p.track(for: p.rows[0]) == nil)
            #expect(p.track(for: p.rows[2])?.url.lastPathComponent == "02.mp3")
            #expect(p.track(for: p.rows[4])?.url.path == "/Music/B/01.mp3")
        }

        @Test("entries are the flat tracks in order")
        func entries() {
            #expect(playlist.entries.map(\.path) == ["/Music/A/01.mp3", "/Music/A/02.mp3", "/Music/B/01.mp3"])
        }

        @Test("headers expand to their tracks, selected tracks stay, nothing twice")
        func expandSelection() {
            let p = playlist
            #expect(p.expandedTrackRows([0]) == [1, 2])
            #expect(p.expandedTrackRows([3, 1]) == [1, 4])
            #expect(p.expandedTrackRows([0, 1, 2, 4]) == [1, 2, 4])
            #expect(p.expandedTrackRows([]).isEmpty)
        }

        @Test("selection counts")
        func counts() {
            let p = playlist
            #expect(p.selectedTrackCount([0, 1, 4]) == 2)
            #expect(p.selectedAlbumCount([0, 1, 4]) == 1)
            #expect(p.selectedAlbumCount([0, 3]) == 2)
            #expect(p.selectedTrackCount([]) == 0)
        }

        @Test("appending adds new albums at the end")
        func appendNew() {
            let added = Make.albums(Make.entries(dir: "C", album: "C", count: 2))
            let result = playlist.appending(added)
            #expect(result.albums.map(\.title) == ["A", "B", "C"])
            #expect(result.trackCount == 5)
        }

        @Test("appending tracks of an album that is already there merges them into it")
        func appendMerges() {
            let more = Make.albums([Make.entry("/Music/A/03.mp3", album: "A", track: 3)])
            let result = playlist.appending(more)
            #expect(result.albums.count == 2)
            #expect(result.albums[0].tracks.count == 3)
            #expect(result.albums[0].tracks.last?.url.lastPathComponent == "03.mp3")
        }

        // MARK: Flat

        /// Interleaved tracks of two albums, as a flat playlist keeps them.
        private var flatEntries: [TrackEntry] {
            [Make.entry("/Music/A/1.mp3", artist: "X", album: "A", track: 1),
             Make.entry("/Music/B/1.mp3", artist: "Y", album: "B", track: 1),
             Make.entry("/Music/A/2.mp3", artist: "X", album: "A", track: 2)]
        }

        @Test("a flat playlist has track rows only and keeps the order")
        func flatRows() {
            let p = Playlist(albums: AlbumBuilder.build(from: flatEntries, flat: true), isFlat: true)
            #expect(p.isFlat)
            #expect(p.rows.count == 3)
            #expect(p.rows.allSatisfy { !$0.isHeader })
            #expect(p.headerRow.isEmpty)
            #expect(p.trackRows == [0..<1, 1..<2, 2..<3])
            #expect(p.trackCount == 3)
            #expect(p.entries.map(\.path) == flatEntries.map(\.path))
            #expect(p.track(for: p.rows[1])?.url.path == "/Music/B/1.mp3")
        }

        @Test("a grouped playlist regroups the same tracks, and back")
        func toggleFlat() {
            let flat = Playlist(albums: AlbumBuilder.build(from: flatEntries, flat: true), isFlat: true)
            let grouped = flat.settingFlat(false)
            #expect(!grouped.isFlat)
            #expect(grouped.albums.map(\.title) == ["A", "B"])
            #expect(grouped.entries.map(\.path) == ["/Music/A/1.mp3", "/Music/A/2.mp3", "/Music/B/1.mp3"])
            #expect(grouped.settingFlat(true).isFlat)
            #expect(grouped.settingFlat(true).rows.count == 3)
        }

        @Test("appending to a flat playlist doesn't group, and tells where the new rows start")
        func flatAppend() {
            let flat = Playlist(albums: AlbumBuilder.build(from: flatEntries, flat: true), isFlat: true)
            let added = Make.albums([Make.entry("/Music/B/2.mp3", artist: "Y", album: "B", track: 2)])
            let result = flat.appending(added)
            #expect(result.isFlat)
            #expect(result.rows.count == 4)
            #expect(result.entries.last?.path == "/Music/B/2.mp3")
            #expect(result.appendedFromRow == 3)
            #expect(playlist.appending(added).appendedFromRow == 5)
            #expect(flat.appendedFromRow == nil)
        }

        // MARK: Editing

        @Test("entry positions of selected rows: headers stand for their tracks")
        func entryIndices() {
            let p = playlist   // 0 header A, 1-2 tracks, 3 header B, 4 track
            #expect(p.entryIndices([1]) == [0])
            #expect(p.entryIndices([4, 2]) == [1, 2])
            #expect(p.entryIndices([0]) == [0, 1])
            #expect(p.entryIndices([3, 1]) == [0, 2])
            #expect(p.entryIndices([]).isEmpty)
            #expect(p.entryIndex(album: 1, track: 0) == 2)

            let flat = Playlist(albums: AlbumBuilder.build(from: flatEntries, flat: true), isFlat: true)
            #expect(flat.entryIndices([0, 2]) == [0, 2])
        }

        @Test("removing tracks regroups the rest; an emptied album disappears")
        func removing() {
            let p = playlist.removing(entries: [2])
            #expect(p.albums.map(\.title) == ["A"])
            #expect(p.entries.map(\.path) == ["/Music/A/01.mp3", "/Music/A/02.mp3"])
            #expect(playlist.removing(entries: [0, 1, 2]).rows.isEmpty)
            #expect(playlist.removing(entries: [7]).trackCount == 3)
        }

        @Test("reloaded tags are taken over, keep the duration and format, and can split an album")
        func updatingTags() {
            let base = Make.playlist([
                Make.entry("/Music/A/1.mp3", album: "A", title: "one", track: 1, duration: 100, codec: "MP3 CBR 320k"),
                Make.entry("/Music/A/2.mp3", album: "A", title: "two", track: 2, duration: 100),
                Make.entry("/Music/A/3.mp3", album: "A", title: "three", track: 3),
            ])
            let changed = Make.result("/Music/A/2.mp3", title: "TWO", album: "A2", track: 9, duration: 5)
            let failed = Make.result("/Music/A/3.mp3", status: .failed("gone"), title: "nope", duration: 7)
            let sameDuration = Make.result("/Music/A/1.mp3", title: "one", album: "A")

            let p = base.updatingTags(from: [changed, failed, sameDuration])
            #expect(p.albums.map(\.title) == ["A", "A2"])
            #expect(p.albums[0].tracks.map(\.title) == ["one", "three"])
            let moved = p.albums[1].tracks[0]
            #expect(moved.title == "TWO")
            #expect(moved.number == 9)
            #expect(moved.duration == 100)                           // playback's value wins over the tag's
            #expect(p.albums[0].tracks[0].codec == "MP3 CBR 320k")
            #expect(p.albums[0].tracks[1].title == "three")           // the failed read left it alone
        }

        @Test("replacing a track's duration and format keeps the rows")
        func replacingTrack() {
            let p = playlist
            let url = URL(fileURLWithPath: "/Music/A/02.mp3")
            let updated = p.replacingTrack(album: 0, track: 1, url: url, duration: 12.5, codec: "FLAC 16/44.1")
            #expect(updated?.albums[0].tracks[1].duration == 12.5)
            #expect(updated?.albums[0].tracks[1].codec == "FLAC 16/44.1")
            #expect(updated?.albums[0].tracks[0].duration == 100)
            #expect(updated?.rows.count == p.rows.count)
            #expect(updated?.trackRows == p.trackRows)
            #expect(p.albums[0].tracks[1].duration == 100)           // immutable

            #expect(p.replacingTrack(album: 0, track: 0, url: url, duration: 1, codec: "x") == nil)   // another file there
            #expect(p.replacingTrack(album: 5, track: 0, url: url, duration: 1, codec: "x") == nil)
            #expect(p.replacingTrack(album: 0, track: 9, url: url, duration: 1, codec: "x") == nil)
        }

        @Test("appending doesn't change the original")
        func immutable() {
            let original = playlist
            _ = original.appending(Make.albums(Make.entries(dir: "C", album: "C", count: 1)))
            #expect(original.albums.count == 2)
        }
    }

    @MainActor @Suite("PlaylistFile")
    struct PlaylistFileTests {
        private func load(_ json: String, in dir: TempDir) throws -> PlaylistFile.LoadResult {
            PlaylistFile.load(from: try dir.write("p.json", Data(json.utf8)))
        }

        private func loaded(_ result: PlaylistFile.LoadResult) -> Playlist? {
            if case .loaded(let p) = result { return p }
            return nil
        }

        @Test("write and load round-trip")
        func roundTrip() throws {
            let dir = try TempDir()
            let playlist = Make.playlist(Make.entries(dir: "A", album: "A", count: 3, year: "2000")
                                         + Make.entries(dir: "B", album: "B", artist: "Other", count: 2))
            let url = dir.path("p.json")
            try PlaylistFile.write(playlist, to: url)

            let result = try #require(loaded(PlaylistFile.load(from: url)))
            #expect(result.entries.map(\.path) == playlist.entries.map(\.path))
            #expect(result.albums.map(\.title) == ["A", "B"])
            #expect(result.albums[0].year == "2000")
            #expect(result.albums[1].artist == "Other")
            #expect(result.albums[0].tracks[0].duration == 100)
        }

        @Test("is_flat is stored and restores a flat playlist")
        func flatFlag() throws {
            let dir = try TempDir()
            let entries = [Make.entry("/M/A/1.mp3", album: "A"), Make.entry("/M/B/1.mp3", album: "B"),
                           Make.entry("/M/A/2.mp3", album: "A")]
            let flat = Playlist(albums: AlbumBuilder.build(from: entries, flat: true), isFlat: true)
            let url = dir.path("p.json")
            try PlaylistFile.write(flat, to: url)

            let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["is_flat"] as? Bool == true)

            let back = try #require(loaded(PlaylistFile.load(from: url)))
            #expect(back.isFlat)
            #expect(back.rows.count == 3 && back.rows.allSatisfy { !$0.isHeader })
            #expect(back.entries.map(\.path) == entries.map(\.path))

            try PlaylistFile.write(Make.playlist(entries), to: url)
            let grouped = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(grouped["is_flat"] as? Bool == false)
        }

        @Test("a file without is_flat (or with a bad one) is grouped")
        func flatDefault() throws {
            let dir = try TempDir()
            for json in [#"{"version": 1, "tracks": [{"path": "/M/A/1.mp3"}]}"#,
                         #"{"version": 1, "is_flat": "yes", "tracks": [{"path": "/M/A/1.mp3"}]}"#] {
                let p = try #require(loaded(try load(json, in: dir)))
                #expect(!p.isFlat)
                #expect(p.rows.count == 2)
            }
        }

        @Test("the file format")
        func format() throws {
            let dir = try TempDir()
            let url = dir.path("p.json")
            try PlaylistFile.write(Make.playlist([Make.entry("/M/A/1.mp3", artist: "Ar", album: "Al", title: "Ti", track: 1)]), to: url)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["version"] as? Int == 1)
            let tracks = try #require(object["tracks"] as? [[String: Any]])
            #expect(tracks.count == 1)
            #expect(tracks[0]["path"] as? String == "/M/A/1.mp3")
            #expect(tracks[0]["codec"] as? String == "MP3")
            #expect(tracks[0]["trackNumber"] as? Int == 1)

            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("\"/M/A/1.mp3\""))                 // slashes aren't escaped
        }

        @Test("albums are rebuilt on load, even for scattered tracks")
        func regroups() throws {
            let dir = try TempDir()
            let json = """
            {"version": 1, "tracks": [
              {"path": "/M/A/1.mp3", "album": "A", "artist": "x"},
              {"path": "/M/B/1.mp3", "album": "B", "artist": "x"},
              {"path": "/M/A/2.mp3", "album": "A", "artist": "x"}]}
            """
            let p = try #require(loaded(try load(json, in: dir)))
            #expect(p.albums.map(\.title) == ["A", "B"])
            #expect(p.albums[0].tracks.count == 2)
        }

        @Test("a missing version is read as an empty playlist (the former {})")
        func versionZero() throws {
            let dir = try TempDir()
            let p = try #require(loaded(try load("{}", in: dir)))
            #expect(p.trackCount == 0)
        }

        @Test("entries without a usable path are dropped, the rest is kept")
        func skipsBadEntries() throws {
            let dir = try TempDir()
            let json = #"{"version": 1, "tracks": [{"path": "/M/A/1.mp3"}, {"path": ""}, {"nope": 1}, 5, {"path": "/M/A/2.mp3"}]}"#
            let p = try #require(loaded(try load(json, in: dir)))
            #expect(p.trackCount == 2)
        }

        @Test("a newer file version is refused")
        func newerVersion() throws {
            let dir = try TempDir()
            let result = try load(#"{"version": 99, "tracks": []}"#, in: dir)
            guard case .invalid(let reason) = result else { Issue.record("expected .invalid"); return }
            #expect(reason.contains("99"))
        }

        @Test("garbage and non-playlist JSON are invalid")
        func invalid() throws {
            let dir = try TempDir()
            for json in ["", "not json", "[1, 2, 3]", #"{"tracks": 5}"#] {
                guard case .invalid = try load(json, in: dir) else { Issue.record("expected .invalid for \(json)"); continue }
            }
        }

        @Test("no file means missing")
        func missing() throws {
            let dir = try TempDir()
            guard case .missing = PlaylistFile.load(from: dir.path("nope.json")) else { Issue.record("expected .missing"); return }
        }

        @Test("an unreadable location is invalid, not missing")
        func unreadable() throws {
            let dir = try TempDir()
            let folder = try dir.mkdir("folder.json")
            guard case .invalid = PlaylistFile.load(from: folder) else { Issue.record("expected .invalid"); return }
        }

        @Test("the empty playlist data loads as no tracks")
        func emptyData() throws {
            let dir = try TempDir()
            let url = try dir.write("p.json", PlaylistFile.emptyData)
            let p = try #require(loaded(PlaylistFile.load(from: url)))
            #expect(p.trackCount == 0)
            #expect(String(decoding: PlaylistFile.emptyData, as: UTF8.self).contains("\"version\":1"))
        }

        @Test("writing replaces an existing file")
        func overwrite() throws {
            let dir = try TempDir()
            let url = dir.path("p.json")
            try PlaylistFile.write(Make.playlist(Make.entries(dir: "A", album: "A", count: 3)), to: url)
            try PlaylistFile.write(Make.playlist(Make.entries(dir: "B", album: "B", count: 1)), to: url)
            let p = try #require(loaded(PlaylistFile.load(from: url)))
            #expect(p.trackCount == 1)
        }
    }
}
