import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("PlaylistStore")
    struct PlaylistStoreTests {
        /// A store on its own temp working directory, loaded.
        private struct Env {
            let dir: TempDir
            let paths: AppPaths
            let config: ConfigStore
            let store: PlaylistStore

            var playlistsDir: URL { paths.playlistsDir }
            func file(_ name: String) -> URL { playlistsDir.appendingPathComponent(name + ".json") }
            func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }
        }

        private func makeEnv(playlists: [String: String] = [:], active: String? = nil, wait: Bool = true) async throws -> Env {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            for (name, json) in playlists { try dir.write("work/playlists/\(name).json", Data(json.utf8)) }
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            if let active { config.update { $0.activePlaylist = active } }
            let store = PlaylistStore(paths: paths, configStore: config)
            let env = Env(dir: dir, paths: paths, config: config, store: store)
            if wait { await settle(store) }
            return env
        }

        private func settle(_ store: PlaylistStore) async {
            let done = await waitUntil { !store.isLoading }
            #expect(done, "playlist did not finish loading")
        }

        private func playlistJSON(_ entries: [TrackEntry], lastPlayed: TrackID? = nil) throws -> String {
            let dir = try TempDir()
            let url = dir.path("x.json")
            try PlaylistFile.write(Make.playlist(entries), lastPlayed: lastPlayed, to: url)
            return try String(contentsOf: url, encoding: .utf8)
        }

        // MARK: Startup

        @Test("creates the main playlist when there are none")
        func createsMain() async throws {
            let env = try await makeEnv()
            #expect(env.store.names == ["main"])
            #expect(env.store.activeName == "main")
            #expect(env.exists("main"))
            #expect(env.store.activePlaylist.trackCount == 0)
        }

        @Test("lists the playlists alphabetically, ignoring other files")
        func listing() async throws {
            let empty = String(decoding: PlaylistFile.emptyData, as: UTF8.self)
            let env = try await makeEnv(playlists: ["beta": empty, "Alpha": empty, "gamma": empty])
            try env.dir.write("work/playlists/notes.txt")
            try env.dir.write("work/playlists/old.json.broken")
            try env.dir.write("work/playlists/.hidden.json")
            let reloaded = PlaylistStore(paths: env.paths, configStore: env.config)
            #expect(reloaded.names == ["Alpha", "beta", "gamma"])
        }

        @Test("the configured playlist is activated and loaded")
        func configuredActive() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 3))
            let env = try await makeEnv(playlists: ["one": json, "two": PlaylistStoreTests.emptyJSON], active: "one")
            #expect(env.store.activeName == "one")
            #expect(env.store.activePlaylist.trackCount == 3)
        }

        @Test("the configured name matches regardless of letter case")
        func configuredCase() async throws {
            let env = try await makeEnv(playlists: ["Rock": Self.emptyJSON], active: "rock")
            #expect(env.store.activeName == "Rock")
        }

        @Test("falls back to the first playlist when the configured one is gone, and says so in the config")
        func missingActive() async throws {
            let env = try await makeEnv(playlists: ["b": Self.emptyJSON, "a": Self.emptyJSON], active: "zzz")
            #expect(env.store.activeName == "a")
            #expect(env.config.config.activePlaylist == "a")
        }

        @Test("loading is asynchronous")
        func asyncLoading() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 2))
            let env = try await makeEnv(playlists: ["main": json], wait: false)
            #expect(env.store.isLoading)
            #expect(env.store.activePlaylist.trackCount == 0)
            await settle(env.store)
            #expect(env.store.activePlaylist.trackCount == 2)
        }

        // MARK: Broken files

        @Test("an unparsable playlist is set aside and replaced by an empty one")
        func quarantine() async throws {
            let env = try await makeEnv(playlists: ["main": "{ definitely not json"])
            #expect(env.store.activePlaylist.trackCount == 0)
            #expect(FileManager.default.fileExists(atPath: env.file("main").path + ".broken"))
            let contents = try String(contentsOf: env.file("main").appendingPathExtension("broken"), encoding: .utf8)
            #expect(contents == "{ definitely not json")
            #expect(env.store.names == ["main"])           // the .broken file isn't a playlist

            let valid = PlaylistFile.load(from: env.file("main"))
            guard case .loaded = valid else { Issue.record("expected an empty playlist file in place"); return }
        }

        @Test("a second broken file doesn't overwrite the first one")
        func secondQuarantine() async throws {
            let env = try await makeEnv(playlists: ["main": "broken"])
            try env.dir.write("work/playlists/main.json", Data("broken again".utf8))
            let store = PlaylistStore(paths: env.paths, configStore: env.config)
            await settle(store)

            let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.playlistsDir.path).filter { $0.hasPrefix("main.json.broken") }
            #expect(leftovers.count == 2)
            let original = try String(contentsOf: env.file("main").appendingPathExtension("broken"), encoding: .utf8)
            #expect(original == "broken")
        }

        @Test("a playlist from a newer version of the app is set aside")
        func newerVersion() async throws {
            let env = try await makeEnv(playlists: ["main": #"{"version": 42, "tracks": []}"#])
            #expect(FileManager.default.fileExists(atPath: env.file("main").path + ".broken"))
        }

        @Test("a playlist file that vanished leaves an empty playlist")
        func vanished() async throws {
            let env = try await makeEnv(playlists: ["a": Self.emptyJSON, "b": Self.emptyJSON], active: "a")
            try FileManager.default.removeItem(at: env.file("b"))
            env.store.setActive("b")        // still in the list, no longer on disk
            await settle(env.store)
            #expect(env.store.activePlaylist.trackCount == 0)
        }

        // MARK: Validation

        @Test("names are trimmed")
        func trimming() throws {
            #expect(try PlaylistStore.validate("  My Playlist \n") == "My Playlist")
            #expect(try PlaylistStore.validate("Ünïcode ☃ 日本語") == "Ünïcode ☃ 日本語")
            #expect(try PlaylistStore.validate("a.b") == "a.b")
        }

        @Test("invalid names", arguments: [
            ("", PlaylistError.emptyName), ("   ", .emptyName),
            ("a/b", .forbiddenCharacters), ("a\\b", .forbiddenCharacters), ("a:b", .forbiddenCharacters),
            ("a*b", .forbiddenCharacters), ("a?b", .forbiddenCharacters), ("a\"b", .forbiddenCharacters),
            ("a<b", .forbiddenCharacters), ("a>b", .forbiddenCharacters), ("a|b", .forbiddenCharacters),
            ("a\tb", .forbiddenCharacters), ("a\u{0}b", .forbiddenCharacters),
            (".hidden", .leadingDot), ("..", .leadingDot),
            (String(repeating: "x", count: 201), .nameTooLong), (String(repeating: "я", count: 101), .nameTooLong),
        ])
        func invalid(name: String, expected: PlaylistError) {
            do {
                _ = try PlaylistStore.validate(name)
                Issue.record("'\(name)' should be invalid")
            } catch {
                #expect("\(error)" == "\(expected)")
            }
        }

        @Test("the length limit is in bytes and inclusive")
        func lengthLimit() throws {
            #expect(try PlaylistStore.validate(String(repeating: "x", count: 200)).count == 200)
            #expect(try PlaylistStore.validate(String(repeating: "я", count: 100)).count == 100)
        }

        @Test("every error has a message")
        func messages() {
            let all: [PlaylistError] = [.emptyName, .forbiddenCharacters, .leadingDot, .nameTooLong,
                                        .alreadyExists("x"), .lastPlaylist, .notFound("x"), .io(CocoaError(.fileNoSuchFile))]
            for e in all { #expect(!(e.errorDescription ?? "").isEmpty) }
            #expect(PlaylistError.alreadyExists("Rock").errorDescription?.contains("Rock") == true)
        }

        // MARK: Create

        @Test("create makes the playlist and activates it")
        func create() async throws {
            let env = try await makeEnv()
            let name = try env.store.create(named: "  Jazz ")
            #expect(name == "Jazz")
            #expect(env.exists("Jazz"))
            #expect(env.store.names == ["Jazz", "main"])
            #expect(env.store.activeName == "Jazz")
            #expect(env.config.config.activePlaylist == "Jazz")
            await settle(env.store)
            #expect(env.store.activePlaylist.trackCount == 0)
        }

        @Test("a name that exists is refused, whatever the letter case or Unicode form")
        func createDuplicate() async throws {
            let env = try await makeEnv()
            #expect(throws: PlaylistError.self) { try env.store.create(named: "main") }
            #expect(throws: PlaylistError.self) { try env.store.create(named: "MAIN") }

            try env.store.create(named: "Café")                  // precomposed é
            await settle(env.store)
            #expect(throws: PlaylistError.self) { try env.store.create(named: "Cafe\u{301}") }   // e + combining accent
            #expect(env.store.names.count == 2)
        }

        @Test("create validates the name")
        func createInvalid() async throws {
            let env = try await makeEnv()
            #expect(throws: PlaylistError.self) { try env.store.create(named: "a/b") }
            #expect(env.store.names == ["main"])
        }

        // MARK: Active playlist

        @Test("switching playlists loads the other one's content")
        func switching() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 4))
            let env = try await makeEnv(playlists: ["full": json, "empty": Self.emptyJSON], active: "empty")
            #expect(env.store.activePlaylist.trackCount == 0)

            env.store.setActive("full")
            #expect(env.store.activeName == "full")
            #expect(env.store.isLoading)
            #expect(env.store.activePlaylist.trackCount == 0)
            await settle(env.store)
            #expect(env.store.activePlaylist.trackCount == 4)
            #expect(env.config.config.activePlaylist == "full")

            env.store.setActive("EMPTY")
            #expect(env.store.activeName == "empty")
            await settle(env.store)
            #expect(env.store.activePlaylist.trackCount == 0)
        }

        @Test("unknown playlists are ignored")
        func unknownActive() async throws {
            let env = try await makeEnv()
            env.store.setActive("nope")
            #expect(env.store.activeName == "main")
            #expect(!env.store.isLoading)
        }

        @Test("selecting the active playlist again doesn't reload it")
        func sameActive() async throws {
            let env = try await makeEnv()
            env.store.setActive("main")
            #expect(!env.store.isLoading)
        }

        @Test("a quick switch back and forth ends up with the right content")
        func rapidSwitch() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 2))
            let env = try await makeEnv(playlists: ["a": json, "b": Self.emptyJSON], active: "a")
            env.store.setActive("b")
            env.store.setActive("a")
            env.store.setActive("b")
            await settle(env.store)
            #expect(env.store.activeName == "b")
            #expect(env.store.activePlaylist.trackCount == 0)
        }

        // MARK: Append

        @Test("append adds albums and writes the file")
        func append() async throws {
            let env = try await makeEnv()
            await env.store.append(Make.albums(Make.entries(dir: "A", album: "A", count: 3)), to: "main")
            #expect(env.store.activePlaylist.trackCount == 3)

            await env.store.flushWrites()
            #expect(!env.store.hasPendingWrites)
            guard case .loaded(let onDisk, _) = PlaylistFile.load(from: env.file("main")) else {
                Issue.record("expected a valid file")
                return
            }
            #expect(onDisk.trackCount == 3)

            await env.store.append(Make.albums(Make.entries(dir: "B", album: "B", count: 2)), to: "MAIN")
            await env.store.flushWrites()
            #expect(env.store.activePlaylist.albums.map(\.title) == ["A", "B"])
            guard case .loaded(let again, _) = PlaylistFile.load(from: env.file("main")) else { return }
            #expect(again.trackCount == 5)
        }

        @Test("the content survives a restart")
        func persistence() async throws {
            let env = try await makeEnv()
            await env.store.append(Make.albums(Make.entries(dir: "A", album: "A", count: 3)), to: "main")
            await env.store.flushWrites()

            let restarted = PlaylistStore(paths: env.paths, configStore: env.config)
            await settle(restarted)
            #expect(restarted.activePlaylist.trackCount == 3)
            #expect(restarted.activePlaylist.albums[0].tracks.map(\.number) == [1, 2, 3])
        }

        @Test("append ignores other playlists, empty input and a playlist that is still loading")
        func appendIgnored() async throws {
            let env = try await makeEnv(playlists: ["a": Self.emptyJSON, "b": Self.emptyJSON], active: "a")
            let albums = Make.albums(Make.entries(dir: "A", album: "A", count: 1))

            await env.store.append(albums, to: "b")
            await env.store.append(albums, to: "unknown")
            await env.store.append([], to: "a")
            #expect(env.store.activePlaylist.trackCount == 0)

            env.store.setActive("b")
            #expect(env.store.isLoading)
            await env.store.append(albums, to: "b")
            await settle(env.store)
            #expect(env.store.activePlaylist.trackCount == 0)
            await env.store.flushWrites()
            #expect(try String(contentsOf: env.file("b"), encoding: .utf8) == Self.emptyJSON)
        }

        @Test("appended tracks of an existing album join it")
        func appendMerge() async throws {
            let env = try await makeEnv()
            await env.store.append(Make.albums(Make.entries(dir: "A", album: "A", count: 2)), to: "main")
            await env.store.append(Make.albums([Make.entry("/Music/A/03.mp3", album: "A", track: 3)]), to: "main")
            #expect(env.store.activePlaylist.albums.count == 1)
            #expect(env.store.activePlaylist.albums[0].tracks.count == 3)
        }

        // MARK: Editing

        private func onDisk(_ env: Env, _ name: String = "main") -> Playlist? {
            if case .loaded(let playlist, _) = PlaylistFile.load(from: env.file(name)) { return playlist }
            return nil
        }

        /// The `last_played` value as it is in the file.
        private func storedLastPlayed(_ env: Env, _ name: String = "main") throws -> TrackID? {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: env.file(name))) as? [String: Any]
            return object?["last_played"] as? Int
        }

        @Test("setFlat regroups, writes is_flat and survives a restart")
        func setFlat() async throws {
            let env = try await makeEnv()
            await env.store.append(Make.albums(Make.entries(dir: "A", album: "A", count: 2)), to: "main")
            #expect(env.store.activePlaylist.rows.count == 3)

            await env.store.setFlat(true)
            #expect(env.store.activePlaylist.isFlat)
            #expect(env.store.activePlaylist.rows.count == 2)
            await env.store.flushWrites()
            #expect(onDisk(env)?.isFlat == true)

            let restarted = PlaylistStore(paths: env.paths, configStore: env.config)
            await settle(restarted)
            #expect(restarted.activePlaylist.isFlat)

            // new files import flat as well
            await restarted.append(Make.albums(Make.entries(dir: "B", album: "B", count: 2)), to: "main")
            #expect(restarted.activePlaylist.rows.count == 4)

            await restarted.setFlat(false)
            #expect(!restarted.activePlaylist.isFlat)
            #expect(restarted.activePlaylist.rows.count == 6)
            await restarted.flushWrites()
            #expect(onDisk(env)?.isFlat == false)
        }

        @Test("remove takes tracks out and writes the file")
        func remove() async throws {
            let env = try await makeEnv()
            await env.store.append(Make.albums(Make.entries(dir: "A", album: "A", count: 3)), to: "main")
            await env.store.remove(ids: [1, 3], from: "main")
            #expect(env.store.activePlaylist.entries.map(\.path) == ["/Music/A/02.mp3"])
            await env.store.flushWrites()
            #expect(onDisk(env)?.trackCount == 1)

            await env.store.remove(ids: [], from: "main")
            await env.store.remove(ids: [2], from: "other")
            #expect(env.store.activePlaylist.trackCount == 1)
        }

        @Test("applyTags takes over the new tags")
        func applyTags() async throws {
            let env = try await makeEnv()
            await env.store.append(Make.albums(Make.entries(dir: "A", album: "A", count: 2)), to: "main")
            await env.store.applyTags([Make.result("/Music/A/02.mp3", title: "New", album: "Other")], to: "main")
            #expect(env.store.activePlaylist.albums.map(\.title) == ["A", "Other"])
            await env.store.flushWrites()
            #expect(onDisk(env)?.albums.map(\.title) == ["A", "Other"])
        }

        @Test("updateTrack changes the playing track, in the active and in a background playlist")
        func updateTrack() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 2))
            let env = try await makeEnv(playlists: ["a": json, "b": Self.emptyJSON], active: "a")
            let store = env.store

            store.updateTrack(id: 2, duration: 7, codec: "X")   // nothing is playing
            #expect(store.activePlaylist.albums[0].tracks[1].duration == 100)

            store.playbackStarted()
            store.updateTrack(id: 99, duration: 7, codec: "X")  // no such track
            #expect(store.activePlaylist.albums[0].tracks[1].duration == 100)
            store.updateTrack(id: 2, duration: 7, codec: "X")
            #expect(store.activePlaylist.albums[0].tracks[1].duration == 7)
            await store.flushWrites()
            #expect(onDisk(env, "a")?.albums[0].tracks[1].codec == "X")

            store.setActive("b")
            await settle(store)
            store.updateTrack(id: 2, duration: 8, codec: "Y")
            #expect(store.playingPlaylist?.albums[0].tracks[1].duration == 8)
            await store.flushWrites()
            #expect(onDisk(env, "a")?.albums[0].tracks[1].codec == "Y")
            #expect(store.activePlaylist.trackCount == 0)
        }

        // MARK: Last played

        @Test("setLastPlayed records the track of the playing playlist and stores it in the file")
        func lastPlayed() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 3))
            let env = try await makeEnv(playlists: ["main": json])
            let store = env.store
            #expect(store.lastPlayedRow == nil)

            store.setLastPlayed(2)                          // nothing is playing
            #expect(store.lastPlayedRow == nil)

            store.playbackStarted()
            store.setLastPlayed(99)                         // no such track
            #expect(store.lastPlayedRow == nil)

            store.setLastPlayed(2)
            #expect(store.lastPlayedRow == 2)               // row 0 is the album header
            await store.flushWrites()
            #expect(try storedLastPlayed(env) == 2)

            let restarted = PlaylistStore(paths: env.paths, configStore: env.config)
            await settle(restarted)
            #expect(restarted.lastPlayedRow == 2)
        }

        @Test("a last_played in the file is available once loaded; one that doesn't exist is not")
        func lastPlayedFromFile() async throws {
            let entries = Make.entries(dir: "A", album: "A", count: 3)
            let env = try await makeEnv(playlists: ["a": try playlistJSON(entries, lastPlayed: 3),
                                                   "b": try playlistJSON(entries, lastPlayed: 3),
                                                   "c": try playlistJSON(entries)], active: "a")
            #expect(env.store.lastPlayedRow == 3)

            env.store.setActive("c")
            await settle(env.store)
            #expect(env.store.lastPlayedRow == nil)

            env.store.setActive("b")
            await settle(env.store)
            #expect(env.store.lastPlayedRow == 3)

            let gone = try playlistJSON(entries, lastPlayed: 3).replacingOccurrences(of: "\"last_played\":3", with: "\"last_played\":77")
            let other = try await makeEnv(playlists: ["main": gone])
            #expect(other.store.lastPlayedRow == nil)
        }

        @Test("the last played track of a playlist is kept while another one is browsed and when coming back")
        func lastPlayedKept() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 3))
            let env = try await makeEnv(playlists: ["a": json, "b": Self.emptyJSON], active: "a")
            let store = env.store
            store.playbackStarted()
            store.setLastPlayed(3)

            store.setActive("b")
            await settle(store)
            #expect(store.lastPlayedRow == nil)

            store.setActive("a")                            // taken back from the background
            #expect(store.lastPlayedRow == 3)

            store.playbackEnded()
            store.setActive("b")
            await settle(store)
            store.setActive("a")                            // read from the file again
            await settle(store)
            #expect(store.lastPlayedRow == 3)
        }

        @Test("a track of the background playlist that starts is stored with that playlist")
        func lastPlayedBackground() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 3))
            let env = try await makeEnv(playlists: ["a": json, "b": Self.emptyJSON], active: "a")
            let store = env.store
            store.playbackStarted()
            store.setActive("b")
            await settle(store)

            store.setLastPlayed(2)
            await store.flushWrites()
            #expect(try storedLastPlayed(env, "a") == 2)
            #expect(try storedLastPlayed(env, "b") == nil)
            #expect(store.lastPlayedRow == nil)             // that's not what is shown
        }

        @Test("removing the last played track forgets it; removing others keeps it")
        func lastPlayedRemoval() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 3))
            let env = try await makeEnv(playlists: ["main": json])
            let store = env.store
            store.playbackStarted()
            store.setLastPlayed(2)

            await store.remove(ids: [1], from: "main")
            #expect(store.lastPlayedRow == 1)               // the same track, one row up
            await store.flushWrites()
            #expect(try storedLastPlayed(env) == 2)

            await store.remove(ids: [2], from: "main")
            #expect(store.lastPlayedRow == nil)
            await store.flushWrites()
            #expect(try storedLastPlayed(env) == nil)
        }

        @Test("the last played track survives tag reloads, regrouping and appends")
        func lastPlayedEdits() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 3))
            let env = try await makeEnv(playlists: ["main": json])
            let store = env.store
            store.playbackStarted()
            store.setLastPlayed(2)

            await store.applyTags([Make.result("/Music/A/02.mp3", title: "New", album: "Other")], to: "main")
            func lastPlayedTitle() -> String? {
                store.lastPlayedRow.flatMap { store.activePlaylist.track(for: store.activePlaylist.rows[$0])?.title }
            }
            #expect(lastPlayedTitle() == "New")

            await store.setFlat(true)
            #expect(lastPlayedTitle() == "New")

            await store.append(Make.albums(Make.entries(dir: "B", album: "B", count: 1)), to: "main")
            #expect(lastPlayedTitle() == "New")
            await store.flushWrites()
            #expect(try storedLastPlayed(env) == 2)
        }

        @Test("renaming keeps the last played track, and later saves still write it")
        func lastPlayedRename() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 3))
            let env = try await makeEnv(playlists: ["main": json])
            let store = env.store
            store.playbackStarted()
            store.setLastPlayed(3)
            try await store.rename("main", to: "renamed")
            #expect(store.lastPlayedRow == 3)
            #expect(try storedLastPlayed(env, "renamed") == 3)

            await store.append(Make.albums(Make.entries(dir: "B", album: "B", count: 1)), to: "renamed")
            await store.flushWrites()
            #expect(try storedLastPlayed(env, "renamed") == 3)
        }

        @Test("many quick changes end with the newest one on disk")
        func lastPlayedBurst() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 10))
            let env = try await makeEnv(playlists: ["main": json])
            let store = env.store
            store.playbackStarted()
            for id in 1...10 { store.setLastPlayed(id) }
            await store.flushWrites()
            #expect(!store.hasPendingWrites)
            #expect(try storedLastPlayed(env) == 10)
            #expect(onDisk(env)?.trackCount == 10)
        }

        @Test("openCount goes up when a playlist has been loaded or taken back from the background")
        func openCount() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 2))
            let env = try await makeEnv(playlists: ["a": json, "b": Self.emptyJSON], active: "a", wait: false)
            let store = env.store
            #expect(store.openCount == 0)
            await settle(store)
            #expect(store.openCount == 1)

            store.playbackStarted()
            store.setActive("b")
            #expect(store.openCount == 1)                   // still loading
            await settle(store)
            #expect(store.openCount == 2)

            store.setActive("a")                            // back at once
            #expect(store.openCount == 3)
            store.setActive("a")                            // already shown
            #expect(store.openCount == 3)
        }

        // MARK: Rename

        @Test("rename moves the file and keeps the content")
        func rename() async throws {
            let env = try await makeEnv()
            await env.store.append(Make.albums(Make.entries(dir: "A", album: "A", count: 2)), to: "main")
            try await env.store.rename("main", to: "Favourites")

            #expect(env.store.names == ["Favourites"])
            #expect(env.store.activeName == "Favourites")
            #expect(env.config.config.activePlaylist == "Favourites")
            #expect(!env.exists("main"))
            #expect(env.exists("Favourites"))
            #expect(env.store.activePlaylist.trackCount == 2)

            let restarted = PlaylistStore(paths: env.paths, configStore: env.config)
            await settle(restarted)
            #expect(restarted.activePlaylist.trackCount == 2)
        }

        @Test("rename waits for a pending write instead of recreating the old file")
        func renameAfterWrite() async throws {
            let env = try await makeEnv()
            await env.store.append(Make.albums(Make.entries(dir: "A", album: "A", count: 1)), to: "main")
            try await env.store.rename("main", to: "other")
            await env.store.flushWrites()
            #expect(!env.exists("main"))
        }

        @Test("rename can change only the letter case")
        func renameCase() async throws {
            let env = try await makeEnv()
            try await env.store.rename("main", to: "MAIN")
            #expect(env.store.names == ["MAIN"])
            #expect(env.store.activeName == "MAIN")
            let names = try FileManager.default.contentsOfDirectory(atPath: env.playlistsDir.path)
            #expect(names == ["MAIN.json"])
        }

        @Test("rename to the same name does nothing")
        func renameSame() async throws {
            let env = try await makeEnv()
            try await env.store.rename("main", to: "main")
            #expect(env.store.names == ["main"])
        }

        @Test("rename refuses existing and invalid names and unknown playlists")
        func renameErrors() async throws {
            let env = try await makeEnv(playlists: ["a": Self.emptyJSON, "b": Self.emptyJSON], active: "a")
            await #expect(throws: PlaylistError.self) { try await env.store.rename("a", to: "B") }
            await #expect(throws: PlaylistError.self) { try await env.store.rename("a", to: "x/y") }
            await #expect(throws: PlaylistError.self) { try await env.store.rename("zzz", to: "c") }
            #expect(env.store.names == ["a", "b"])
        }

        @Test("renaming an inactive playlist keeps the active one")
        func renameInactive() async throws {
            let env = try await makeEnv(playlists: ["a": Self.emptyJSON, "b": Self.emptyJSON], active: "a")
            try await env.store.rename("b", to: "c")
            #expect(env.store.names == ["a", "c"])
            #expect(env.store.activeName == "a")
        }

        // MARK: Delete

        @Test("delete removes the file")
        func delete() async throws {
            let env = try await makeEnv(playlists: ["a": Self.emptyJSON, "b": Self.emptyJSON], active: "a")
            try await env.store.delete("b")
            #expect(env.store.names == ["a"])
            #expect(!env.exists("b"))
            #expect(env.store.activeName == "a")
        }

        @Test("deleting the active playlist activates the first remaining one")
        func deleteActive() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 2))
            let env = try await makeEnv(playlists: ["a": Self.emptyJSON, "b": json, "c": Self.emptyJSON], active: "b")
            #expect(env.store.activePlaylist.trackCount == 2)
            try await env.store.delete("b")
            await settle(env.store)
            #expect(env.store.activeName == "a")
            #expect(env.store.activePlaylist.trackCount == 0)
            #expect(env.config.config.activePlaylist == "a")
        }

        @Test("the last playlist can't be deleted; unknown ones are an error")
        func deleteErrors() async throws {
            let env = try await makeEnv()
            await #expect(throws: PlaylistError.self) { try await env.store.delete("main") }
            await #expect(throws: PlaylistError.self) { try await env.store.delete("nope") }
            #expect(env.exists("main"))
        }

        @Test("delete matches names regardless of case")
        func deleteCase() async throws {
            let env = try await makeEnv(playlists: ["a": Self.emptyJSON, "Beta": Self.emptyJSON], active: "a")
            try await env.store.delete("beta")
            #expect(env.store.names == ["a"])
        }

        // MARK: Exists

        @Test("exists ignores letter case")
        func exists() async throws {
            let env = try await makeEnv()
            #expect(env.store.exists("main"))
            #expect(env.store.exists("MaIn"))
            #expect(!env.store.exists("other"))
        }

        // MARK: Playback hold

        @Test("the playing playlist stays in memory while another one is browsed")
        func playbackHold() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 2))
            let env = try await makeEnv(playlists: ["a": json, "b": Self.emptyJSON], active: "a")
            let store = env.store
            let playlistA = store.activePlaylist

            #expect(store.playingPlaylist == nil)
            store.playbackStarted()
            #expect(store.playingName == "a")
            #expect(store.playingPlaylist === playlistA)

            store.setActive("b")
            await settle(store)
            #expect(store.activePlaylist.trackCount == 0)
            #expect(store.playingPlaylist === playlistA)         // held in the background

            store.setActive("a")
            #expect(!store.isLoading)                              // taken back as is, no reload
            #expect(store.activePlaylist === playlistA)
            #expect(store.playingPlaylist === playlistA)
        }

        @Test("when playback ends the background playlist is released")
        func playbackEnded() async throws {
            let json = try playlistJSON(Make.entries(dir: "A", album: "A", count: 2))
            let env = try await makeEnv(playlists: ["a": json, "b": Self.emptyJSON], active: "a")
            let store = env.store
            store.playbackStarted()
            store.setActive("b")
            await settle(store)
            store.playbackEnded()
            #expect(store.playingName == nil)
            #expect(store.playingPlaylist == nil)

            store.setActive("a")
            #expect(store.isLoading)                               // loaded from disk again
        }

        @Test("playback can't start while the playlist is loading")
        func playbackNotWhileLoading() async throws {
            let env = try await makeEnv(wait: false)
            env.store.playbackStarted()
            #expect(env.store.playingName == nil)
            await settle(env.store)
        }

        @Test("renaming the playing playlist keeps it playing")
        func renamePlaying() async throws {
            let env = try await makeEnv()
            env.store.playbackStarted()
            try await env.store.rename("main", to: "renamed")
            #expect(env.store.playingName == "renamed")
            #expect(env.store.playingPlaylist != nil)
        }

        private static let emptyJSON = String(decoding: PlaylistFile.emptyData, as: UTF8.self)
    }
}
