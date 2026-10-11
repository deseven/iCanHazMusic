// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    /// Tracks of CUE sheets as the rest of the app sees them: tag results, playlist entries and their file format,
    /// grouping, editing and export.
    @MainActor @Suite("CUE tracks in playlists")
    struct CueModelTests {
        private func cueTrack(number: Int = 1, track: Int? = nil, audio: String = "/Music/A/album.flac",
                              sheet: String = "/Music/A/album.cue", start: Double = 0, end: Double? = 100,
                              title: String? = "Song", artist: String? = "Artist", albumArtist: String? = nil,
                              album: String? = "Album", year: String? = "1999", fileTracks: Int = 2) -> CueTrack {
            CueTrack(sheet: URL(fileURLWithPath: sheet), pathNumber: number, trackNumber: track ?? number,
                     audio: URL(fileURLWithPath: audio), start: start, end: end, title: title, artist: artist,
                     albumArtist: albumArtist, album: album, year: year, fileTrackCount: fileTracks)
        }

        /// The result of reading an audio file whose tags are `fields` (the finished tags are made out of them).
        private func taggedFile(_ fields: [TagField: String], path: String = "/Music/A/album.flac",
                                duration: TimeInterval? = 600) -> TagReadResult {
            var raw = RawTags()
            for (field, value) in fields { raw.set(field, value) }
            raw.duration = duration
            let (tags, status) = TagReader.finalize(raw: raw, failed: nil)
            return TagReadResult(id: 0, url: URL(fileURLWithPath: path), tags: tags, status: status, sources: ["test"],
                                 elapsed: 0, rawFields: raw.fields, artwork: .none)
        }

        private let fileTags: [TagField: String] = [
            .title: "File Title", .artist: "File Artist", .album: "File Album", .year: "2005", .track: "9",
            .lyrics: "la la",
        ]

        private func audioResult(_ path: String = "/Music/A/album.flac", status: TagReadStatus = .complete,
                                 duration: TimeInterval? = 600, artwork: ArtworkSource = .none) -> TagReadResult {
            Make.result(path, status: status, duration: duration, artwork: artwork)
        }

        /// A playlist entry of a CUE track.
        private func entry(_ number: Int, sheet: String = "/Music/A/album.cue", file: String = "/Music/A/album.flac",
                           start: Double = 0, end: Double? = 100, title: String? = nil, album: String = "Album",
                           artist: String = "Artist", duration: TimeInterval? = nil) -> TrackEntry {
            TrackEntry(path: CuePath.make(sheet: sheet, number: number), artist: artist, album: album,
                       title: title ?? "Song \(number)", trackNumber: number, year: "1999", duration: duration ?? end.map { $0 - start },
                       codec: "FLAC", cue: CueSlice(sheet: sheet, number: number, file: file, start: start, end: end))
        }

        // MARK: - Tag results

        @Test("a track's tags are the sheet's")
        func tags() {
            let result = cueTrack(number: 3, track: 7, start: 100, end: 160.5).tagResult(id: 4, from: audioResult())
            #expect(result.id == 4)
            #expect(result.status == .complete)
            #expect(result.tags.title == "Song" && result.tags.artist == "Artist" && result.tags.album == "Album")
            #expect(result.tags.year == "1999")
            #expect(result.tags.trackNumber == 7)
            #expect(result.tags.duration == 60.5)
            #expect(result.url.path == "/Music/A/album.cue:3")
            #expect(result.cue == CueSlice(sheet: "/Music/A/album.cue", number: 3, file: "/Music/A/album.flac", start: 100, end: 160.5))
            #expect(result.sources.first == "CUE")
            #expect(result.tags.lyrics == nil)
        }

        @Test("the last track of a file is as long as what is left of the file")
        func lastTrackDuration() {
            let track = cueTrack(start: 450, end: nil)
            #expect(track.tagResult(id: 0, from: audioResult(duration: 600)).tags.duration == 150)
            #expect(track.tagResult(id: 0, from: audioResult(duration: nil)).tags.duration == nil)
            #expect(track.tagResult(id: 0, from: audioResult(duration: 450)).tags.duration == nil)   // nothing left
            #expect(track.tagResult(id: 0, from: audioResult(duration: 400)).tags.duration == nil)   // the sheet lies
        }

        @Test("the artist is the track's, else the sheet's performer, else Unknown Artist")
        func artistFallback() {
            let own = cueTrack(artist: "Own", albumArtist: "Sheet").tagResult(id: 0, from: audioResult())
            #expect(own.tags.artist == "Own")
            let sheet = cueTrack(artist: nil, albumArtist: "Sheet").tagResult(id: 0, from: audioResult())
            #expect(sheet.tags.artist == "Sheet")
            #expect(sheet.status == .complete)
            let none = cueTrack(artist: nil, albumArtist: nil).tagResult(id: 0, from: audioResult())
            #expect(none.tags.artist == TagFallback.artist)
            #expect(none.status == .partial(fallbacks: ["artist"]))
        }

        @Test("missing title and album get the usual fallbacks, and the track is still there")
        func fallbacks() {
            let noTitle = cueTrack(title: nil).tagResult(id: 0, from: audioResult())
            #expect(noTitle.tags.title == TagFallback.title)
            #expect(noTitle.status == .partial(fallbacks: ["title"]))
            #expect(AlbumBuilder.isUsable(noTitle.status))

            let noAlbum = cueTrack(album: nil).tagResult(id: 0, from: audioResult())
            #expect(noAlbum.tags.album == TagFallback.album)
            #expect(noAlbum.status == .partial(fallbacks: ["album"]))

            let noYear = cueTrack(year: nil).tagResult(id: 0, from: audioResult())
            #expect(noYear.tags.year == nil)
            #expect(noYear.status == .complete)
        }

        @Test("a sheet that says nothing about a track still gives a track (not the no-tags failure a bare file would be)")
        func nothingAtAll() {
            let bare = cueTrack(title: nil, artist: nil, albumArtist: nil, album: nil, year: nil)
                .tagResult(id: 0, from: audioResult())
            #expect(bare.tags.title == TagFallback.title)
            #expect(bare.tags.artist == TagFallback.artist)
            #expect(bare.tags.album == TagFallback.album)
            #expect(bare.status == .partial(fallbacks: ["title", "artist", "album"]))
            #expect(AlbumBuilder.isUsable(bare.status))
            #expect(!TagFallback.isIdentified(artist: bare.tags.artist, title: bare.tags.title))
        }

        @Test("blank values are missing values")
        func blank() {
            let result = cueTrack(title: "   ", artist: "\t", albumArtist: "", album: "  ", year: " ")
                .tagResult(id: 0, from: audioResult())
            #expect(result.tags.title == TagFallback.title)
            #expect(result.tags.artist == TagFallback.artist)
            #expect(result.tags.album == TagFallback.album)
            #expect(result.tags.year == nil)
        }

        @Test("the year is taken out of a date")
        func yearFromDate() {
            #expect(cueTrack(year: "1987-05-02").tagResult(id: 0, from: audioResult()).tags.year == "1987")
        }

        @Test("a track whose audio file can't be read fails, with the file named")
        func unreadableAudio() {
            let result = cueTrack().tagResult(id: 2, from: audioResult(status: .failed("file not found")))
            guard case .failed(let reason) = result.status else {
                Issue.record("expected a failure, got \(result.status)")
                return
            }
            #expect(reason.contains("album.flac") && reason.contains("file not found"))
            #expect(!AlbumBuilder.isUsable(result.status))
            #expect(result.url.path == "/Music/A/album.cue:1")
        }

        @Test("a file with no tags of its own is no problem: the tags are the sheet's")
        func untaggedAudio() {
            let result = cueTrack().tagResult(id: 0, from: audioResult(status: .noTags))
            #expect(result.status == .complete)
        }

        @Test("art: a folder image or the embedded picture of the audio file count for the sheet's album")
        func artwork() {
            for art in [ArtworkSource.cover("cover.jpg"), .anyImage("x.png"), .embedded, .none] {
                let result = cueTrack().tagResult(id: 0, from: audioResult(artwork: art))
                #expect(result.artwork == art)
            }
        }

        @Test("art: with the audio file in another directory, only its embedded picture counts")
        func artworkElsewhere() {
            let track = cueTrack(audio: "/Music/Other/album.flac")
            let file = { (art: ArtworkSource) in self.audioResult("/Music/Other/album.flac", artwork: art) }
            #expect(track.tagResult(id: 0, from: file(.embedded)).artwork == .embedded)
            #expect(track.tagResult(id: 0, from: file(.cover("cover.jpg"))).artwork == .none)
            #expect(track.tagResult(id: 0, from: file(.anyImage("x.png"))).artwork == .none)
        }

        // MARK: - Sheet or file first

        @Test("a sheet cuts its file when the file has several tracks, or the track leaves a part of it out")
        func cutsFile() {
            #expect(cueTrack(start: 0, end: nil, fileTracks: 1).cutsFile == false)
            #expect(cueTrack(start: 0, end: nil, fileTracks: 2).cutsFile)
            #expect(cueTrack(start: 0, end: 50, fileTracks: 1).cutsFile)
            #expect(cueTrack(start: 2.5, end: nil, fileTracks: 1).cutsFile)   // skips the pregap
        }

        @Test("a sheet that cuts: its values first, the file fills in what it lacks, never title and lyrics of other tracks")
        func cutSheetFirst() {
            let file = taggedFile(fileTags)
            let full = cueTrack(track: 4, title: "Sheet Title", artist: "Sheet Artist", album: "Sheet Album", year: "1999")
                .tagResult(id: 0, from: file)
            #expect(full.tags.title == "Sheet Title" && full.tags.artist == "Sheet Artist")
            #expect(full.tags.album == "Sheet Album" && full.tags.year == "1999" && full.tags.trackNumber == 4)

            let bare = cueTrack(track: 4, title: nil, artist: nil, album: nil, year: nil).tagResult(id: 0, from: file)
            #expect(bare.tags.artist == "File Artist" && bare.tags.album == "File Album" && bare.tags.year == "2005")
            #expect(bare.tags.title == TagFallback.title)   // the file's title is not this track's
            #expect(bare.tags.trackNumber == 4)             // the sheet's TRACK, not the file's 9
            #expect(bare.tags.lyrics == nil)
            #expect(bare.status == .partial(fallbacks: ["title"]))
            #expect(bare.cue != nil)
        }

        @Test("a sheet's album performer beats the file's artist when the sheet cuts")
        func cutAlbumPerformer() {
            let result = cueTrack(artist: nil, albumArtist: "Sheet").tagResult(id: 0, from: taggedFile(fileTags))
            #expect(result.tags.artist == "Sheet")
        }

        @Test("a track cut out of a file all of its own is that file's track: its title and lyrics count")
        func cutOnlyTrack() {
            let result = cueTrack(start: 2, end: nil, title: nil, fileTracks: 1).tagResult(id: 0, from: taggedFile(fileTags))
            #expect(result.tags.title == "File Title" && result.tags.lyrics == "la la")
            #expect(result.cue?.start == 2)
            #expect(result.tags.duration == 598)
        }

        @Test("a sheet that only lists its file: the file's values first, the sheet fills in what the file lacks")
        func listingSheetFileFirst() {
            let track = cueTrack(number: 3, track: 5, start: 0, end: nil, title: "Sheet Title", artist: "Sheet Artist",
                                 album: "Sheet Album", year: "1999", fileTracks: 1)
            let own = track.importResult(id: 7, from: taggedFile(fileTags))
            #expect(own.id == 7)
            #expect(own.url.path == "/Music/A/album.flac" && own.cue == nil)   // the file itself
            #expect(own.tags.title == "File Title" && own.tags.artist == "File Artist" && own.tags.album == "File Album")
            #expect(own.tags.year == "2005" && own.tags.trackNumber == 9 && own.tags.lyrics == "la la")
            #expect(own.tags.duration == 600)
            #expect(own.status == .complete)

            // Missing in the file: from the sheet; the track number too.
            let partial = track.importResult(id: 0, from: taggedFile([.title: "File Title"]))
            #expect(partial.tags.title == "File Title")
            #expect(partial.tags.artist == "Sheet Artist" && partial.tags.album == "Sheet Album")
            #expect(partial.tags.year == "1999" && partial.tags.trackNumber == 5)
            #expect(partial.cue == nil)

            // A file that has no tags is given the sheet's.
            let bare = track.importResult(id: 0, from: taggedFile([:]))
            #expect(bare.tags.title == "Sheet Title" && bare.tags.artist == "Sheet Artist" && bare.status == .complete)
            #expect(bare.url.path == "/Music/A/album.flac" && bare.cue == nil)
        }

        @Test("a listing sheet that says nothing, for a file that says nothing: the file stays the no-tags file it is")
        func listingSheetNothing() {
            let track = cueTrack(start: 0, end: nil, title: nil, artist: nil, albumArtist: nil, album: nil, year: nil, fileTracks: 1)
            let result = track.importResult(id: 0, from: taggedFile([:]))
            #expect(result.status == .noTags && result.cue == nil)
        }

        @Test("a listing sheet's file that can't be read is that file's failure")
        func listingSheetUnreadable() {
            let track = cueTrack(start: 0, end: nil, fileTracks: 1)
            let result = track.importResult(id: 3, from: audioResult(status: .failed("file not found")))
            #expect(result.id == 3 && result.status == .failed("file not found") && result.cue == nil)
        }

        @Test("an import of a track that is cut is the part with the pseudo path")
        func importCutIsPart() {
            let result = cueTrack(number: 2).importResult(id: 0, from: taggedFile(fileTags))
            #expect(result.url.path == "/Music/A/album.cue:2" && result.cue != nil)
        }

        @Test("reloading a part keeps it a part, even if the sheet doesn't cut the file any more")
        func reloadKeepsPart() {
            let result = cueTrack(start: 0, end: nil, title: "Sheet Title", fileTracks: 1).tagResult(id: 0, from: taggedFile(fileTags))
            #expect(result.url.path == "/Music/A/album.cue:1" && result.cue != nil)
            #expect(result.tags.title == "File Title")   // the file comes first when the sheet doesn't cut
        }

        // MARK: - Entries

        @Test("an entry made of a track result: pseudo path, the audio file, the sheet's directory")
        func entryFromResult() {
            let result = cueTrack(number: 2, start: 10, end: 20, title: nil).tagResult(id: 0, from: audioResult())
            let entry = TrackEntry(result: result)
            #expect(entry.path == "/Music/A/album.cue:2")
            #expect(entry.url.path == "/Music/A/album.flac")
            #expect(entry.directory.path == "/Music/A")
            #expect(entry.codec == "FLAC")
            #expect(entry.cue?.start == 10 && entry.cue?.end == 20)
            #expect(entry.title == TagFallback.title)   // not "album", which would be the "file name"
            #expect(entry.duration == 10)
        }

        @Test("a plain file's entry is untouched: its own file name as the missing title, no cue")
        func plainEntry() {
            let entry = TrackEntry(result: Make.result("/Music/A/Some Song.mp3", title: nil))
            #expect(entry.title == "Some Song")
            #expect(entry.cue == nil)
            #expect(entry.url.path == "/Music/A/Some Song.mp3")
            #expect(entry.directory.path == "/Music/A")
        }

        @Test("the audio file may be in another directory; the track is shown with its sheet")
        func entryDirectory() {
            let result = cueTrack(audio: "/Music/Audio/album.flac").tagResult(id: 0, from: audioResult("/Music/Audio/album.flac"))
            let entry = TrackEntry(result: result)
            #expect(entry.directory.path == "/Music/A")
            #expect(entry.url.path == "/Music/Audio/album.flac")
        }

        // MARK: - The playlist file

        @Test("a CUE track is stored by its pseudo path and says where its audio is")
        func fileFormat() throws {
            let dir = try TempDir()
            let url = dir.path("p.json")
            let playlist = Make.playlist([entry(1, start: 0, end: 12.5), entry(2, start: 12.5, end: nil)])
            try PlaylistFile.write(playlist, to: url)

            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("\"path\":\"/Music/A/album.cue:1\""))
            #expect(text.contains("\"cue\":{\"end\":12.5,\"file\":\"/Music/A/album.flac\",\"start\":0}"))
            #expect(text.contains("\"cue\":{\"file\":\"/Music/A/album.flac\",\"start\":12.5}"))   // no end: omitted
        }

        @Test("a playlist with CUE tracks reads back the same, in order, with the IDs they had")
        func roundTrip() throws {
            let dir = try TempDir()
            let url = dir.path("p.json")
            let plain = Make.entry("/Music/B/x.mp3", album: "Other", track: 1, duration: 5)
            let playlist = Make.playlist([entry(1, end: 100), entry(2, start: 100, end: 250.25), entry(3, start: 250.25, end: nil), plain])
            try PlaylistFile.write(playlist, lastPlayed: 2, to: url)

            guard case .loaded(let loaded, let lastPlayed) = PlaylistFile.load(from: url) else {
                Issue.record("not loaded")
                return
            }
            #expect(lastPlayed == 2)
            #expect(loaded.entries.map(\.path) == playlist.entries.map(\.path))
            #expect(loaded.entries.map(\.id) == playlist.entries.map(\.id))
            #expect(loaded.entries.map(\.cue) == playlist.entries.map(\.cue))
            #expect(loaded.entries.map(\.duration) == playlist.entries.map(\.duration))
            #expect(loaded.entries.compactMap(\.cue).map(\.number) == [1, 2, 3])
            #expect(loaded.entries.last?.cue == nil)
            #expect(Set(loaded.entries.map(\.id)).count == 4)
        }

        @Test("a hand-written entry: title and format may be missing")
        func lenientDecoding() throws {
            let json = #"{"path":"/m/a.cue:4","cue":{"file":"/m/a.WAV","start":1.5}}"#
            let entry = try JSONDecoder().decode(TrackEntry.self, from: Data(json.utf8))
            #expect(entry.cue == CueSlice(sheet: "/m/a.cue", number: 4, file: "/m/a.WAV", start: 1.5, end: nil))
            #expect(entry.title == TagFallback.title)
            #expect(entry.artist == TagFallback.artist && entry.album == TagFallback.album)
            #expect(entry.codec == "WAV")
            #expect(entry.id == unassignedTrackID)
        }

        @Test("a pseudo path without the audio's place can't be played and is dropped; the rest of the playlist loads")
        func missingCueObject() throws {
            let dir = try TempDir()
            let json = """
            {"version":1,"next_id":4,"tracks":[
              {"id":1,"path":"/m/a.cue:1","title":"no audio"},
              {"id":2,"path":"/m/b.mp3","title":"plain"},
              {"id":3,"path":"/m/a.cue:2","cue":{"file":"/m/a.flac","start":0},"title":"fine"}
            ]}
            """
            let url = try dir.write("p.json", Data(json.utf8))
            guard case .loaded(let playlist, _) = PlaylistFile.load(from: url) else {
                Issue.record("not loaded")
                return
            }
            #expect(playlist.entries.map(\.title) == ["plain", "fine"])
        }

        @Test("a cue object on an ordinary path means nothing")
        func cueOnPlainPath() throws {
            let json = #"{"path":"/m/b.mp3","title":"T","cue":{"file":"/m/a.flac","start":0}}"#
            let entry = try JSONDecoder().decode(TrackEntry.self, from: Data(json.utf8))
            #expect(entry.cue == nil)
            #expect(entry.url.path == "/m/b.mp3")
        }

        @Test("old playlists (no cue anywhere) read as before")
        func oldFormat() throws {
            let json = #"{"id":5,"path":"/m/b.mp3","artist":"A","album":"B","title":"T","codec":"MP3"}"#
            let entry = try JSONDecoder().decode(TrackEntry.self, from: Data(json.utf8))
            #expect(entry.cue == nil && entry.id == 5 && entry.title == "T")
            let data = try JSONEncoder().encode(entry)
            #expect(!String(decoding: data, as: UTF8.self).contains("cue"))
        }

        // MARK: - Albums

        @Test("the tracks of one sheet make one album, shown in the sheet's directory")
        func albumGrouping() {
            let albums = Make.albums([entry(1), entry(2, start: 100), entry(3, start: 200, end: nil)])
            #expect(albums.count == 1)
            #expect(albums[0].tracks.count == 3)
            #expect(albums[0].directory.path == "/Music/A")
            #expect(albums[0].title == "Album")
            #expect(albums[0].tracks.map(\.number) == [1, 2, 3])
            #expect(albums[0].tracks.map(\.path) == ["/Music/A/album.cue:1", "/Music/A/album.cue:2", "/Music/A/album.cue:3"])
            #expect(albums[0].tracks.allSatisfy { $0.url.path == "/Music/A/album.flac" })
        }

        @Test("a sheet is an album by its own directory and album name, not by its audio file's")
        func albumKey() {
            let elsewhere = entry(1, sheet: "/Music/A/album.cue", file: "/Music/Audio/album.flac")
            let sameDirectory = entry(2, sheet: "/Music/A/other.cue", file: "/Music/A/other.flac")
            let albums = Make.albums([elsewhere, sameDirectory])
            #expect(albums.count == 1)
            #expect(albums[0].key == AlbumKey.make(directory: URL(fileURLWithPath: "/Music/A"), title: "Album"))
        }

        @Test("two sheets with different album names stay apart, a plain file next to a sheet is its own album")
        func separateAlbums() {
            let albums = Make.albums([
                entry(1, sheet: "/Music/A/one.cue", album: "One"), entry(1, sheet: "/Music/A/two.cue", album: "Two"),
                Make.entry("/Music/A/bonus.mp3", album: "Bonus"),
            ])
            #expect(albums.map(\.title) == ["One", "Two", "Bonus"])
        }

        @Test("a compilation sheet: tracks with other artists make Various Artists")
        func compilation() {
            let albums = Make.albums([entry(1, artist: "X"), entry(2, artist: "Y")])
            #expect(albums[0].hasMultipleArtists)
            #expect(albums[0].artist == AlbumBuilder.variousArtists)
        }

        @Test("a flat playlist keeps every track on its own")
        func flat() {
            let playlist = Make.playlist([entry(1), entry(2, start: 100)]).settingFlat(true)
            #expect(playlist.albums.count == 2)
            #expect(playlist.entries.allSatisfy { $0.cue != nil })
            #expect(playlist.settingFlat(false).albums.count == 1)
        }

        // MARK: - Track values

        @Test("a track knows where it is stored, what plays and what to show in Finder")
        func trackValues() throws {
            let playlist = Make.playlist([entry(2, start: 10, end: 20), Make.entry("/Music/B/x.mp3", album: "Other")])
            let cue = try #require(playlist.albums[0].tracks.first)
            #expect(cue.path == "/Music/A/album.cue:2")
            #expect(cue.url.path == "/Music/A/album.flac")
            #expect(cue.source == PlaybackSource(url: URL(fileURLWithPath: "/Music/A/album.flac"), start: 10, end: 20))
            #expect(cue.revealURL.path == "/Music/A/album.cue")
            #expect(cue.entryURL.path == "/Music/A/album.cue:2")

            let plain = try #require(playlist.albums[1].tracks.first)
            #expect(plain.path == "/Music/B/x.mp3")
            #expect(plain.source == PlaybackSource(url: URL(fileURLWithPath: "/Music/B/x.mp3")))
            #expect(plain.revealURL.path == "/Music/B/x.mp3" && plain.entryURL.path == "/Music/B/x.mp3")
        }

        @Test("two tracks of one file are different sources")
        func sourcesDiffer() throws {
            let tracks = Make.playlist([entry(1, end: 100), entry(2, start: 100, end: 200)]).albums[0].tracks
            #expect(tracks[0].source != tracks[1].source)
            #expect(tracks[0].source.url == tracks[1].source.url)
        }

        // MARK: - Editing a playlist

        @Test("every track of a sheet has an ID of its own, also when the same sheet is added twice")
        func ids() {
            let first = Make.playlist([entry(1), entry(2, start: 100)])
            let second = first.appending(Make.albums([entry(1), entry(2, start: 100)]))
            let ids = second.entries.map(\.id)
            #expect(ids.count == 4 && Set(ids).count == 4)
            #expect(Array(ids.prefix(2)) == first.entries.map(\.id))
            #expect(second.entries.map(\.path) == ["/Music/A/album.cue:1", "/Music/A/album.cue:2", "/Music/A/album.cue:1", "/Music/A/album.cue:2"])
        }

        @Test("tracks of a sheet can be rearranged and removed one by one; what is left plays as before")
        func rearranging() throws {
            let playlist = Make.playlist([entry(1, end: 100), entry(2, start: 100, end: 200), entry(3, start: 200, end: nil)])
            let ids = playlist.entries.map(\.id)

            let moved = try #require(playlist.movingTrack(id: ids[2], toIndexInAlbum: 0))
            #expect(moved.albums[0].tracks.map(\.id) == [ids[2], ids[0], ids[1]])
            #expect(moved.albums[0].tracks.map(\.cue?.number) == [3, 1, 2])
            #expect(moved.albums[0].tracks[0].source.start == 200 && moved.albums[0].tracks[0].source.end == nil)

            let reordered = Make.playlist(moved.entries)   // as stored and read again
            #expect(reordered.albums[0].tracks.map(\.cue?.number) == [3, 1, 2])

            let removed = moved.removing(ids: [ids[0]])
            #expect(removed.entries.map(\.cue?.number) == [3, 2])
            #expect(removed.entries.map(\.id) == [ids[2], ids[1]])
        }

        @Test("what playback learns about a track (length, format) is kept with its cue")
        func replacing() throws {
            let playlist = Make.playlist([entry(1, end: 100), entry(2, start: 100, end: nil)])
            let id = playlist.entries[1].id
            let updated = try #require(playlist.replacingTrack(id: id, duration: 321.5, codec: "FLAC 24/96"))
            let track = try #require(updated.track(id: id))
            #expect(track.duration == 321.5 && track.codec == "FLAC 24/96")
            #expect(track.cue == CueSlice(sheet: "/Music/A/album.cue", number: 2, file: "/Music/A/album.flac", start: 100, end: nil))
        }

        @Test("IDs given to tracks that come without one keep the cue")
        func unassignedIDs() {
            let albums = Make.albums([entry(1), entry(2, start: 100)])
            let playlist = Playlist(albums: albums)
            #expect(playlist.entries.map(\.id) == [1, 2])
            #expect(playlist.entries.allSatisfy { $0.cue != nil })
        }

        // MARK: - Reloading tags

        @Test("reloading takes the sheet's new values and places, keeps the ID and what playback measured")
        func updatingTags() {
            let old = entry(2, start: 100, end: 200, title: "Old", duration: 99.7)
            let playlist = Make.playlist([entry(1, end: 100), old])
            let id = playlist.entries[1].id

            let fresh = cueTrack(number: 2, start: 110, end: 230, title: "New").tagResult(id: 0, from: audioResult())
            let updated = playlist.updatingTags(from: [fresh])

            let track = updated.track(id: id)
            #expect(track?.title == "New")
            #expect(track?.cue?.start == 110 && track?.cue?.end == 230)
            #expect(track?.duration == 120)               // the sheet knows better than the old measurement
            #expect(track?.codec == "FLAC")               // from playback, not re-derived
            #expect(updated.track(id: playlist.entries[0].id)?.title == "Song 1")
        }

        @Test("reloading the last track of a file keeps its measured length")
        func updatingLastTrack() {
            let playlist = Make.playlist([entry(1, start: 0, end: nil, duration: 411.2)])
            let fresh = cueTrack(number: 1, start: 0, end: nil, title: "New").tagResult(id: 0, from: audioResult(duration: 410))
            let updated = playlist.updatingTags(from: [fresh])
            #expect(updated.entries[0].duration == 411.2)
            #expect(updated.entries[0].title == "New")
        }

        @Test("a failed read changes nothing")
        func updatingFailed() {
            let playlist = Make.playlist([entry(1, title: "Keep")])
            let failed = cueTrack(number: 1, title: "X").tagResult(id: 0, from: audioResult(status: .failed("gone")))
            #expect(playlist.updatingTags(from: [failed]).entries[0].title == "Keep")
        }

        @Test("a sheet that now puts the track in another album regroups it")
        func updatingRegroups() {
            let playlist = Make.playlist([entry(1), entry(2, start: 100)])
            let fresh = cueTrack(number: 2, start: 100, album: "Renamed").tagResult(id: 0, from: audioResult())
            let updated = playlist.updatingTags(from: [fresh])
            #expect(updated.albums.map(\.title) == ["Album", "Renamed"])
        }

        // MARK: - Export

        @Test("tracks of sheets are left out of an export and counted; the other entries are written as always")
        func exportSkipsCue() {
            let entries = [
                Make.entry("/Music/B/one.mp3", artist: "A", title: "One", duration: 10),
                entry(1), entry(2, start: 100),
                Make.entry("/Music/B/two.mp3", artist: "A", title: "Two", duration: 20),
            ]
            for format in PlaylistFormat.allCases {
                let export = PlaylistExchange.export(entries, format: format)
                let text = String(decoding: export.data, as: UTF8.self)
                #expect(export.skipped == 2, "\(format)")
                #expect(text.contains("/Music/B/one.mp3") && text.contains("/Music/B/two.mp3"), "\(format)")
                #expect(!text.contains(".cue") && !text.contains("album.flac"), "\(format)")
            }
            let pls = String(decoding: PlaylistExchange.export(entries, format: .pls).data, as: UTF8.self)
            #expect(pls.contains("NumberOfEntries=2"))
            #expect(pls.contains("File2=/Music/B/two.mp3"))
        }

        @Test("an export without any CUE track skips nothing and is what it was")
        func exportWithoutCue() {
            let entries = [Make.entry("/Music/B/one.mp3", artist: "A", title: "One", duration: 10)]
            for format in PlaylistFormat.allCases {
                let export = PlaylistExchange.export(entries, format: format)
                #expect(export.skipped == 0)
                #expect(export.data == PlaylistExchange.data(for: entries, format: format))
            }
        }

        @Test("a playlist of nothing but CUE tracks exports an empty list and counts them all")
        func exportOnlyCue() {
            let export = PlaylistExchange.export([entry(1), entry(2, start: 100)], format: .m3u8)
            #expect(export.skipped == 2)
            #expect(String(decoding: export.data, as: UTF8.self) == "#EXTM3U\n")
        }
    }
}
