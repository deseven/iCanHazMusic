import Carbon
import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Hotkey")
    struct HotkeyTests {
        // MARK: - Text form

        @Test("accepts modifier+key combinations")
        func acceptsModifierCombos() {
            for string in ["⌘G", "⌘⇧G", "⌥⌘F", "⌃⌥⌘⇧1", "⌘⇧␣", "⌃⌥F19", "⇧Clear", "⌃⇧G"] {
                #expect(Hotkey(string: string) != nil, "\(string)")
            }
        }

        @Test("rejects empty strings, strings without a key and unknown keys")
        func rejectsNonsense() {
            for string in ["", "⌘", "⌘⇧", "⌘Ü", "⌘Foo", "⌘GG"] {
                #expect(Hotkey(string: string) == nil, "\(string)")
            }
        }

        @Test("F-keys work without modifiers, other keys don't")
        func modifierRules() {
            #expect(Hotkey(string: "F13") != nil)
            #expect(Hotkey(string: "F20") != nil)
            #expect(Hotkey(string: "Clear") != nil)
            #expect(Hotkey(string: "G") == nil)
            #expect(Hotkey(string: "␣") == nil)
            #expect(Hotkey(string: "↑") == nil)
        }

        @Test("shift alone is only enough for keys that aren't typed")
        func shiftOnly() {
            #expect(Hotkey(string: "⇧G") == nil)
            #expect(Hotkey(string: "⇧1") == nil)
            #expect(Hotkey(string: "⇧F5") != nil)
            #expect(Hotkey(string: "⇧↑") != nil)
            #expect(Hotkey(string: "⇧⎋") != nil)
            #expect(Hotkey(string: "⇧⌫") != nil)
        }

        @Test("the text form is canonical: modifiers in order, shifted symbols as their key")
        func canonicalForm() throws {
            #expect(try #require(Hotkey(string: "⌘⇧⌥⌃G")).string == "⌃⌥⇧⌘G")
            #expect(try #require(Hotkey(string: "⌘!")).string == "⌘1")
            #expect(try #require(Hotkey(string: "⌘?")).string == "⌘/")
            #expect(try #require(Hotkey(string: "F13")).string == "F13")
        }

        @Test("every key of the table survives a round trip")
        func roundTrip() throws {
            for code in UInt32(0)...0x7F {
                guard let name = Hotkey.keyName(for: code) else { continue }
                let hotkey = try #require(Hotkey(keyCode: code, modifiers: [.command]), "\(name)")
                #expect(Hotkey(string: hotkey.string) == hotkey, "\(name)")
                #expect(hotkey.keyCode == code)
            }
        }

        // MARK: - Key codes

        @Test("validates by key code and modifiers")
        func validatesByKeyCode() {
            #expect(Hotkey.isValid(keyCode: 0x05, modifiers: [.command]))               // ⌘G
            #expect(!Hotkey.isValid(keyCode: 0x05, modifiers: []))                      // G
            #expect(Hotkey.isValid(keyCode: 0x69, modifiers: []))                       // F13
            #expect(!Hotkey.isValid(keyCode: 0x7F, modifiers: [.command]))              // unknown key
            #expect(!Hotkey.isValid(keyCode: 0x05, modifiers: [.shift]))                // ⇧G
            #expect(Hotkey.isValid(keyCode: 0x69, modifiers: [.shift]))                 // ⇧F13
            #expect(Hotkey.isValid(keyCode: 0x05, modifiers: [.command, .shift]))       // ⇧⌘G
        }

        @Test("builds the text form from a key code")
        func fromKeyCode() {
            #expect(Hotkey(keyCode: 0x05, modifiers: [.command, .shift])?.string == "⇧⌘G")
            #expect(Hotkey(keyCode: 0x31, modifiers: [.control, .option, .shift, .command])?.string == "⌃⌥⇧⌘␣")
            #expect(Hotkey(keyCode: 0x69, modifiers: [])?.string == "F13")
            #expect(Hotkey(keyCode: 0x7F, modifiers: [.command]) == nil)
        }

        @Test("key names")
        func keyNames() {
            #expect(Hotkey.keyName(for: 0x00) == "A")
            #expect(Hotkey.keyName(for: 0x35) == "⎋")
            #expect(Hotkey.keyName(for: 0x7F) == nil)
        }

        // MARK: - Carbon

        @Test("modifiers map to Carbon flags")
        func carbonFlags() {
            #expect(HotkeyModifiers([]).carbonFlags == 0)
            #expect(HotkeyModifiers.command.carbonFlags == UInt32(cmdKey))
            #expect(HotkeyModifiers([.command, .shift]).carbonFlags == UInt32(cmdKey) | UInt32(shiftKey))
            #expect(HotkeyModifiers([.control, .option]).carbonFlags == UInt32(controlKey) | UInt32(optionKey))
        }

        @Test("four character codes")
        func fourCharCode() {
            #expect(GlobalHotkeyManager.fourCharCode("ichm") == 0x6963_686D)
        }
    }

    // MARK: - HotkeyService

    /// Registers into a dictionary instead of the system, and presses keys on request.
    @MainActor private final class StubBackend: HotkeyBackend {
        private var entries: [HotkeyID: (hotkey: Hotkey, handler: @MainActor () -> Void)] = [:]
        private var next: UInt32 = 1
        /// Combinations that are taken by "another app".
        var taken: Set<Hotkey> = []
        private(set) var registrations = 0

        var registered: Set<Hotkey> { Set(entries.values.map(\.hotkey)) }

        func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) throws -> HotkeyID {
            if taken.contains(hotkey) { throw HotkeyError.registrationFailed(OSStatus(eventHotKeyExistsErr)) }
            let id = HotkeyID(value: next)
            next += 1
            entries[id] = (hotkey, handler)
            registrations += 1
            return id
        }

        func unregister(_ id: HotkeyID) {
            entries[id] = nil
        }

        /// What the system does when the combination is pressed.
        func press(_ hotkey: Hotkey) {
            for entry in entries.values where entry.hotkey == hotkey { entry.handler() }
        }
    }

    @MainActor @Suite("HotkeyService")
    struct HotkeyServiceTests {
        private struct Env {
            let dir: TempDir
            let paths: AppPaths
            let config: ConfigStore
            let backend: StubBackend
            let playback: PlaybackState
            let service: HotkeyService
        }

        /// `keepSearchDefault`: the search hotkey has its default one; else it is cleared, so the tests of the other
        /// hotkeys needn't list it.
        private func makeEnv(config configure: (inout AppConfig) -> Void = { _ in }, taken: [String] = [],
                             started: Bool = true, keepSearchDefault: Bool = false) async throws -> Env {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.path("work"))
            let config = ConfigStore(paths: paths, saveDelay: .seconds(60))
            if !keepSearchDefault { config.update { $0.hotkeys[.search] = "" } }
            config.update(configure)
            let store = PlaylistStore(paths: paths, configStore: config)
            #expect(await waitUntil { !store.isLoading })
            let playback = PlaybackState(store: store, engine: EngineRig().engine, tickInterval: nil)
            let backend = StubBackend()
            backend.taken = Set(taken.compactMap { Hotkey(string: $0) })
            let service = HotkeyService(configStore: config, backend: backend, playback: playback)
            if started { service.start() }
            return Env(dir: dir, paths: paths, config: config, backend: backend, playback: playback, service: service)
        }

        private func key(_ string: String) throws -> Hotkey {
            try #require(Hotkey(string: string))
        }

        @Test("nothing is registered before start, and by default nothing at all")
        func nothingByDefault() async throws {
            let env = try await makeEnv(started: false)
            #expect(env.service.mediaKeys)
            #expect(HotkeyAction.allCases.allSatisfy { env.service.hotkeyString(for: $0).isEmpty })
            env.service.start()
            #expect(env.backend.registered.isEmpty)
        }

        @Test("the configured hotkeys are registered at start")
        func registersConfigured() async throws {
            let env = try await makeEnv(config: {
                $0.hotkeys[.playPause] = "⌃⌥P"
                $0.hotkeys[.volumeUp] = "⌃⌥↑"
            }, started: false)
            #expect(env.backend.registered.isEmpty)
            env.service.start()
            #expect(env.backend.registered == [try key("⌃⌥P"), try key("⌃⌥↑")])
            #expect(env.service.hotkeyString(for: .playPause) == "⌃⌥P")
        }

        @Test("search has ⇧⌘W by default, which opens the search")
        func searchDefault() async throws {
            let env = try await makeEnv(started: false, keepSearchDefault: true)
            #expect(env.service.hotkeyString(for: .search) == "⇧⌘W")
            #expect(HotkeyAction.allCases.first == .search)
            #expect(HotkeyAction.allCases.filter { $0 != .search }.allSatisfy { env.service.hotkeyString(for: $0).isEmpty })

            var opened = 0
            env.service.onSearch = { opened += 1 }
            env.service.start()
            #expect(env.backend.registered == [try key("⇧⌘W")])
            env.backend.press(try key("⇧⌘W"))
            #expect(opened == 1)
        }

        @Test("pressing a hotkey does what its action says")
        func pressing() async throws {
            let env = try await makeEnv(config: {
                $0.hotkeys[.volumeUp] = "⌃⌥↑"
                $0.hotkeys[.volumeDown] = "⌃⌥↓"
            })
            env.playback.volume = 0.5
            env.backend.press(try key("⌃⌥↑"))
            #expect(env.playback.volume == 0.55)
            env.backend.press(try key("⌃⌥↓"))
            env.backend.press(try key("⌃⌥↓"))
            #expect(env.playback.volume == 0.45)
        }

        @Test("every action is wired to something")
        func everyActionPerforms() async throws {
            // Nothing plays and nothing is loaded, so none of them may do anything but also none may crash.
            let env = try await makeEnv()
            for action in HotkeyAction.allCases { env.service.perform(action) }
            #expect(env.playback.status == .stopped)
        }

        @Test("setting a hotkey registers it, replaces the old one and keeps it in the config")
        func setting() async throws {
            let env = try await makeEnv()
            env.service.setHotkey(try key("⌃⌥P"), for: .playPause)
            #expect(env.backend.registered == [try key("⌃⌥P")])
            #expect(env.config.config.hotkeys[.playPause] == "⌃⌥P")

            env.service.setHotkey(try key("⌃⌥O"), for: .playPause)
            #expect(env.backend.registered == [try key("⌃⌥O")])
            #expect(env.config.config.hotkeys[.playPause] == "⌃⌥O")

            env.service.setHotkey(nil, for: .playPause)
            #expect(env.backend.registered.isEmpty)
            #expect(env.config.config.hotkeys[.playPause].isEmpty)
        }

        @Test("a combination only belongs to one action: the new one takes it")
        func moving() async throws {
            let env = try await makeEnv(config: { $0.hotkeys[.nextTrack] = "⌃⌥N" })
            env.service.setHotkey(try key("⌃⌥N"), for: .nextAlbum)
            #expect(env.service.hotkeyString(for: .nextAlbum) == "⌃⌥N")
            #expect(env.service.hotkeyString(for: .nextTrack).isEmpty)
            #expect(env.config.config.hotkeys[.nextTrack].isEmpty)
            #expect(env.config.config.hotkeys[.nextAlbum] == "⌃⌥N")
            #expect(env.backend.registered == [try key("⌃⌥N")])
        }

        @Test("a combination that is taken is reported and doesn't stop the others")
        func taken() async throws {
            let env = try await makeEnv(config: {
                $0.hotkeys[.playPause] = "⌃⌥P"
                $0.hotkeys[.nextTrack] = "⌃⌥N"
            }, taken: ["⌃⌥P"])
            #expect(env.service.failed == [.playPause])
            #expect(env.backend.registered == [try key("⌃⌥N")])
            #expect(env.service.hotkeyString(for: .playPause) == "⌃⌥P")   // kept, it may become free

            env.service.setHotkey(try key("⌃⌥Q"), for: .playPause)
            #expect(env.service.failed.isEmpty)
            #expect(env.backend.registered == [try key("⌃⌥N"), try key("⌃⌥Q")])
        }

        @Test("no hotkeys are registered while one is being recorded")
        func recording() async throws {
            let env = try await makeEnv(config: { $0.hotkeys[.playPause] = "⌃⌥P" })
            #expect(env.backend.registered == [try key("⌃⌥P")])

            env.service.setRecording(true)
            #expect(env.service.isRecording)
            #expect(env.backend.registered.isEmpty)

            env.service.setHotkey(try key("⌃⌥Q"), for: .playPause)   // recorded: still off until the end
            #expect(env.backend.registered.isEmpty)

            env.service.setRecording(false)
            #expect(env.backend.registered == [try key("⌃⌥Q")])
        }

        @Test("a failure is remembered while recording")
        func failureWhileRecording() async throws {
            let env = try await makeEnv(config: { $0.hotkeys[.playPause] = "⌃⌥P" }, taken: ["⌃⌥P"])
            env.service.setRecording(true)
            #expect(env.service.failed == [.playPause])
            env.service.setRecording(false)
            #expect(env.service.failed == [.playPause])
        }

        @Test("the media keys setting is kept in the config")
        func mediaKeys() async throws {
            let env = try await makeEnv(config: { $0.hotkeys.mediaKeys = false })
            #expect(!env.service.mediaKeys)
            env.service.mediaKeys = true
            #expect(env.config.config.hotkeys.mediaKeys)
            env.service.mediaKeys = false
            #expect(!env.config.config.hotkeys.mediaKeys)
        }

        @Test("hotkeys survive a restart")
        func persistence() async throws {
            let env = try await makeEnv()
            env.service.setHotkey(try key("⌃⌥P"), for: .playPause)
            env.service.mediaKeys = false
            env.config.flush()

            let reloaded = ConfigStore(paths: env.paths, saveDelay: .seconds(60))
            let second = HotkeyService(configStore: reloaded, backend: StubBackend(), playback: env.playback)
            #expect(second.hotkeyString(for: .playPause) == "⌃⌥P")
            #expect(!second.mediaKeys)
        }
    }
}
