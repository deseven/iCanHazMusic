import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Search")
    struct SearchTests {
        // MARK: Matching

        private func word(_ text: String) -> SearchString { SearchText.fold(text) }

        private func match(_ query: String, in fields: String...) -> FieldMatch? {
            FuzzyMatcher.match(SearchText.tokens(of: query), in: fields.map { SearchText.fold($0) })
        }

        @Test("case, accents and width are ignored")
        func folding() {
            #expect(match("beyonce", in: "Beyoncé")?.isExact == true)
            #expect(match("BEYONCÉ", in: "beyonce")?.isExact == true)
            #expect(match("motley", in: "Mötley Crüe")?.isExact == true)
            #expect(match("ＡＢＣ", in: "abc")?.isExact == true)
        }

        @Test("a word is found anywhere in a field, better at the start of a word, at the start of the field and as the whole")
        func exactRanking() throws {
            let whole = try #require(match("love", in: "Love"))
            let start = try #require(match("love", in: "Love Song"))
            let wordStart = try #require(match("love", in: "My Love"))
            let inside = try #require(match("love", in: "Glove"))
            #expect([whole, start, wordStart, inside].allSatisfy { $0.isExact })
            #expect(whole.score > start.score)
            #expect(start.score > wordStart.score)
            #expect(wordStart.score > inside.score)

            let long = try #require(match("love", in: "Love and other things you can do"))
            #expect(start.score > long.score)       // the shorter field is the better one
        }

        @Test("every word of the query has to be found, in any of the fields")
        func severalWords() {
            #expect(match("pink money", in: "Money", "Pink Floyd", "The Dark Side")?.isExact == true)
            #expect(match("pink wall", in: "Money", "Pink Floyd", "The Dark Side") == nil)
            #expect(match("   ", in: "x") == nil)
            #expect(match("", in: "x") == nil)
        }

        @Test("fuzzy: letters in order and close together")
        func subsequence() {
            let found = match("pfloyd", in: "Pink Floyd")
            #expect(found?.isExact == false)
            #expect(match("pnk", in: "Pink")?.isExact == false)
            #expect(match("zeppelin", in: "Led Zeppelin")?.isExact == true)
            #expect(match("ldzpn", in: "Led Zeppelin") == nil)           // spread too far
            #expect(match("pf", in: "Pink Floyd") == nil)                // too short for fuzzy
            #expect(match("fp", in: "Pink Floyd") == nil)
        }

        @Test("fuzzy: a typo")
        func typos() {
            #expect(match("floid", in: "Pink Floyd")?.isExact == false)  // a letter wrong
            #expect(match("pnik", in: "Pink Floyd")?.isExact == false)   // two swapped
            #expect(match("floy", in: "Pink Floyd")?.isExact == true)    // that is a part
            #expect(match("flooyd", in: "Pink Floyd")?.isExact == false) // a letter more
            #expect(match("abc", in: "abd") == nil)                      // too short for typos
            #expect(match("floxxd", in: "Pink Floyd") == nil)            // two wrong in a short word
        }

        @Test("exact matches are better than fuzzy ones")
        func exactBeatsFuzzy() throws {
            let exact = try #require(match("pink", in: "Pink"))
            let fuzzy = try #require(match("pnik", in: "Pink"))
            #expect(exact.isExact && !fuzzy.isExact)
            // One fuzzy word makes the whole query fuzzy.
            #expect(match("pink floid", in: "Pink Floyd")?.isExact == false)
        }

        // MARK: Search

        private func entries(_ dir: String, artist: String, album: String, titles: [String], year: String? = nil) -> [TrackEntry] {
            titles.enumerated().map { i, title in
                Make.entry("/Music/\(dir)/\(String(format: "%02d", i + 1)).mp3", artist: artist, album: album, title: title,
                           track: i + 1, year: year)
            }
        }

        private func index(_ name: String, _ entries: [TrackEntry], flat: Bool = false) -> SearchIndex {
            SearchIndex(name: name, playlist: Playlist(albums: AlbumBuilder.build(from: entries, flat: flat), isFlat: flat))
        }

        private func search(_ query: String, _ indexes: [SearchIndex], names: [String]? = nil,
                            preferred: String? = nil, limit: Int = SearchEngine.defaultLimit) -> [SearchResult] {
            SearchEngine.search(query, indexes: indexes, playlistNames: names ?? indexes.map(\.name), preferred: preferred,
                                limit: limit)
        }

        private var floyd: [TrackEntry] {
            entries("Floyd/Wall", artist: "Pink Floyd", album: "The Wall", titles: ["In the Flesh", "Another Brick", "Comfortably Numb"],
                    year: "1979")
                + entries("Floyd/Dark", artist: "Pink Floyd", album: "The Dark Side of the Moon", titles: ["Speak to Me", "Money", "Time"],
                          year: "1973")
        }

        @Test("tracks and albums are found by artist, title and album; an album shows its artist, name and year")
        func kinds() {
            let main = index("main", floyd)
            let money = search("money", [main])
            #expect(money.map(\.kind) == [.track])
            #expect(money.first?.text == "Pink Floyd – Money")
            #expect(money.first?.playlist == "main")

            let wall = search("the wall", [main])
            #expect(wall.first?.kind == .album)
            #expect(wall.first?.text == "Pink Floyd – The Wall (1979)")
            #expect(wall.first?.trackID == main.playlist.albums[0].tracks[0].id)   // an album is its first track
            #expect(wall.first?.title == "The Wall")

            // Artist and title across fields, the album name for a track.
            #expect(search("floyd time", [main]).first?.text == "Pink Floyd – Time")
            #expect(search("moon time", [main]).first?.text == "Pink Floyd – Time")
            #expect(search("", [main]).isEmpty)
            #expect(search("   ", [main]).isEmpty)
            #expect(search("nothing like it", [main]).isEmpty)
        }

        @Test("the tracks of a found album aren't listed with it, unless their own title matches")
        func albumHidesItsTracks() {
            let main = index("main", floyd)
            let byArtist = search("pink floyd", [main])
            #expect(byArtist.map(\.kind) == [.album, .album])
            #expect(byArtist.map(\.title) == ["The Wall", "The Dark Side of the Moon"])

            // A track whose title has the whole query stays.
            let moon = search("moon", [main])
            #expect(moon.map(\.kind) == [.album])
            let extra = entries("Floyd/Dark", artist: "Pink Floyd", album: "The Dark Side of the Moon", titles: ["Moon River"])
            let withMoon = index("main", floyd + extra)
            let found = search("moon", [withMoon])
            #expect(found.map(\.kind) == [.track, .album])          // the track's title is the better match
            #expect(found.contains { $0.title == "Moon River" })
            #expect(!found.contains { $0.title == "Time" })
        }

        @Test("a flat playlist has no albums, only tracks")
        func flat() {
            let main = index("main", floyd, flat: true)
            let found = search("wall", [main])
            #expect(found.count == 3)
            #expect(found.allSatisfy { $0.kind == .track })
            #expect(search("money", [main]).map(\.text) == ["Pink Floyd – Money"])
        }

        @Test("the playing playlist's entries come first, then the others'; exact before fuzzy inside each")
        func ranking() {
            let a = index("a", entries("a", artist: "Band", album: "Songs", titles: ["Moon River"]))
            let b = index("b", entries("b", artist: "Band", album: "Songs", titles: ["Moon Dance"]))

            #expect(search("moon", [a, b], preferred: "b").map(\.playlist) == ["b", "a"])
            #expect(search("moon", [a, b], preferred: "a").map(\.playlist) == ["a", "b"])
            #expect(search("moon", [a, b]).map(\.playlist) == ["a", "b"])     // else the order of the playlists

            // A fuzzy match in the first group is still before an exact one in the second.
            let fuzzy = index("fuzzy", entries("f", artist: "Band", album: "Songs", titles: ["Mon River"]))
            let exact = index("exact", entries("e", artist: "Band", album: "Songs", titles: ["Moon River"]))
            #expect(search("moon", [fuzzy, exact], preferred: "fuzzy").map(\.playlist) == ["fuzzy", "exact"])
            #expect(search("moon", [fuzzy, exact], preferred: "exact").map(\.playlist) == ["exact", "fuzzy"])

            // Inside one playlist exact comes first, whatever the order is.
            let mixed = index("m", entries("m", artist: "Band", album: "Songs", titles: ["Moan", "Hello Moon"]))
            #expect(search("moon", [mixed]).map(\.title) == ["Hello Moon", "Moan"])
        }

        @Test("results of equal rank: better match first, then playlists, albums, tracks")
        func order() {
            let main = index("main", entries("x", artist: "Moon", album: "Moon", titles: ["Moon"]))
            // Playlists first; the same score for the album and its track: the album first.
            let kinds = search("moon", [main], names: ["main", "Moon"]).map(\.kind)
            #expect(kinds == [.playlist, .album, .track])

            let whole = index("w", entries("w", artist: "Someone", album: "Else", titles: ["Moon", "Moonlight Sonata", "A Long Title With Moon Inside"]))
            #expect(search("moon", [whole]).map(\.title) == ["Moon", "Moonlight Sonata", "A Long Title With Moon Inside"])
        }

        @Test("playlists are found by name, only if there is more than one")
        func playlists() {
            let one = index("Jazz", entries("j", artist: "Miles", album: "Kind of Blue", titles: ["So What"]))
            #expect(search("jazz", [one]).isEmpty)

            let two = index("Rock", entries("r", artist: "Band", album: "Songs", titles: ["Jazz Hands"]))
            let found = search("jazz", [one, two], preferred: "Rock")
            #expect(found.map(\.kind) == [.playlist, .track])                  // before everything else
            #expect(found.first?.text == "Jazz")
            #expect(found.first?.playlist == "Jazz")
            #expect(found.first?.trackID == nil)

            // Also before the entries of the playing playlist, however good they match.
            let playing = index("Jazz", entries("n", artist: "Jazz", album: "Jazz", titles: ["Jazz"]))
            #expect(search("jazz", [playing, two], preferred: "Jazz").first?.kind == .playlist)

            // Only the whole name finds a playlist: no fuzzy matching, no part of a name.
            let names = ["test", "Testing", "My Mix", "my"]
            #expect(search("TEST", [], names: names).map(\.playlist) == ["test"])
            #expect(search("tes", [], names: names).isEmpty)
            #expect(search("tset", [], names: names).isEmpty)
            #expect(search("testing", [], names: names).map(\.playlist) == ["Testing"])
            #expect(search("  my ", [], names: names).map(\.playlist) == ["my"])
            #expect(search("my  mix", [], names: names).map(\.playlist) == ["My Mix"])
            #expect(search("mix", [], names: names).isEmpty)
            #expect(search("my mi", [], names: names).isEmpty)

            // A playlist that isn't in memory yet is found too.
            #expect(search("later", [one], names: ["Jazz", "Later"]).map(\.playlist) == ["Later"])
        }

        @Test("without playlist search no playlist is a result")
        func playlistsOff() {
            let one = index("Jazz", entries("j", artist: "Miles", album: "Kind of Blue", titles: ["So What"]))
            let two = index("Rock", entries("r", artist: "Band", album: "Songs", titles: ["Jazz Hands"]))
            let query = "jazz"
            #expect(search(query, [one, two]).first?.kind == .playlist)

            let found = SearchEngine.search(query, indexes: [one, two], playlistNames: ["Jazz", "Rock"], preferred: nil,
                                            options: SearchOptions(playlists: false))
            #expect(found.map(\.kind) == [.track])
            #expect(found.first?.text == "Band – Jazz Hands")
        }

        @Test("without album search no album is a result and the album name isn't searched")
        func albumsOff() {
            let main = index("main", floyd)
            let options = SearchOptions(albums: false)
            func find(_ query: String) -> [SearchResult] {
                SearchEngine.search(query, indexes: [main], playlistNames: ["main"], preferred: nil, options: options)
            }

            // By artist: every track, no album.
            let byArtist = find("pink floyd")
            #expect(byArtist.count == 6)
            #expect(byArtist.allSatisfy { $0.kind == .track })
            // The album's name finds neither the album nor its tracks.
            #expect(find("the wall").isEmpty)
            #expect(find("moon").isEmpty)
            #expect(find("money").map(\.text) == ["Pink Floyd – Money"])
            #expect(find("floyd time").map(\.text) == ["Pink Floyd – Time"])

            // A compilation's tracks are still found by their own artist, but "Various Artists" is an album's.
            let compilation = index("c", [Make.entry("/Music/V/01.mp3", artist: "Daft Punk", album: "Hits", title: "Around the World", track: 1),
                                         Make.entry("/Music/V/02.mp3", artist: "Moby", album: "Hits", title: "Porcelain", track: 2)])
            let found = SearchEngine.search("daft", indexes: [compilation], playlistNames: ["c"], preferred: nil, options: options)
            #expect(found.map(\.text) == ["Daft Punk – Around the World"])
            #expect(SearchEngine.search("various", indexes: [compilation], playlistNames: ["c"], preferred: nil, options: options).isEmpty)
        }

        @Test("without fuzzy search only parts of the text are found")
        func fuzzyOff() {
            let main = index("main", floyd)
            let off = SearchOptions(fuzzy: false)
            func find(_ query: String, _ options: SearchOptions) -> [SearchResult] {
                SearchEngine.search(query, indexes: [main], playlistNames: ["main"], preferred: nil, options: options)
            }
            #expect(find("mony", SearchOptions()).map(\.text) == ["Pink Floyd – Money"])      // a typo
            #expect(find("cmfrtbl", SearchOptions()).map(\.text) == ["Pink Floyd – Comfortably Numb"])
            #expect(find("mony", off).isEmpty)
            #expect(find("cmfrtbl", off).isEmpty)
            #expect(find("floid", off).isEmpty)
            #expect(find("money", off).map(\.text) == ["Pink Floyd – Money"])
            #expect(find("pink mon", off).map(\.text) == ["Pink Floyd – Money"])
        }

        @Test("the options tell when tracks are the only kind of result")
        func tracksOnly() {
            #expect(!SearchOptions().tracksOnly)
            #expect(!SearchOptions(playlists: false).tracksOnly)
            #expect(!SearchOptions(albums: false).tracksOnly)
            #expect(SearchOptions(playlists: false, albums: false).tracksOnly)
        }

        @Test("the number of results is limited")
        func limit() {
            let many = index("main", entries("m", artist: "Band", album: "Songs", titles: (1...40).map { "Song \($0)" }))
            #expect(search("song", [many]).count == SearchEngine.defaultLimit)
            #expect(SearchEngine.defaultLimit == 10)
            #expect(search("song", [many], limit: 3).count == 3)
        }

        @Test("a compilation's tracks are found by their own artist")
        func compilation() {
            let entries = [Make.entry("/Music/V/01.mp3", artist: "Daft Punk", album: "Hits", title: "Around the World", track: 1),
                           Make.entry("/Music/V/02.mp3", artist: "Moby", album: "Hits", title: "Porcelain", track: 2)]
            let main = index("main", entries)
            #expect(main.playlist.albums[0].artist == "Various Artists")
            #expect(search("daft", [main]).map(\.text) == ["Daft Punk – Around the World"])
            #expect(search("various", [main]).map(\.kind) == [.album])
        }

        // MARK: Searcher

        @Test("the searcher finds things in the playlists that are in memory, and follows changes")
        func searcher() async throws {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            let store = PlaylistStore(paths: paths, configStore: config)
            #expect(await waitUntil { !store.isLoading })
            await store.append(Make.albums(floyd), to: "main")
            let searcher = PlaylistSearcher(store: store)

            #expect(await searcher.search("money").map(\.text) == ["Pink Floyd – Money"])
            #expect(await searcher.search("zzzz").isEmpty)
            #expect(await searcher.search("").isEmpty)

            try store.create(named: "Other")
            #expect(await waitUntil { !store.isLoading && !store.isPreloading })
            await store.append(Make.albums(entries("o", artist: "Other Band", album: "Other", titles: ["Money Talks"])), to: "Other")

            // The active playlist (Other) comes first; each playlist is named in the results now.
            let found = await searcher.search("money")
            #expect(found.map(\.playlist) == ["Other", "main"])
            #expect(found.map(\.text) == ["Other Band – Money Talks", "Pink Floyd – Money"])
            // The playlist a track is played from comes first, not the one that is shown.
            store.setActive("main")
            store.playbackStarted()
            store.setActive("Other")
            #expect(await searcher.search("money").map(\.playlist) == ["main", "Other"])
            let byName = await searcher.search("other")
            #expect(byName.contains { $0.kind == .playlist && $0.playlist == "Other" })

            // The searcher follows its settings.
            let settings = SearchSettings()
            let narrow = PlaylistSearcher(store: store, settings: settings)
            settings.byPlaylistName = false
            #expect(await narrow.search("other").allSatisfy { $0.kind != .playlist })
            settings.byAlbumName = false
            #expect(await narrow.search("other").allSatisfy { $0.kind == .track })
            settings.fuzzy = false
            #expect(await narrow.search("mony").isEmpty)
        }
    }
}
