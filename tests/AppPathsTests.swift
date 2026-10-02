import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("AppPaths")
    struct AppPathsTests {
        @Test("uses the default directory without the option")
        func defaultDirectory() {
            let url = AppPaths.resolveWorkDir(arguments: ["iCanHazMusic"])
            #expect(url.path == AppPaths.defaultWorkDir.path)
            #expect(url.lastPathComponent == AppPaths.workDirName)
        }

        @Test("--workdir with a separate value")
        func separateValue() {
            let url = AppPaths.resolveWorkDir(arguments: ["app", "--workdir", "/tmp/ichm-x"])
            #expect(url.path == "/tmp/ichm-x")
        }

        @Test("--workdir=value")
        func equalsForm() {
            let url = AppPaths.resolveWorkDir(arguments: ["app", "--workdir=/tmp/ichm-y"])
            #expect(url.path == "/tmp/ichm-y")
        }

        @Test("expands ~ and resolves relative paths")
        func tildeAndRelative() {
            let home = AppPaths.resolveWorkDir(arguments: ["app", "--workdir", "~/ichm-z"])
            #expect(home.path == NSHomeDirectory() + "/ichm-z")

            let relative = AppPaths.resolveWorkDir(arguments: ["app", "--workdir", "some/dir"])
            #expect(relative.path.hasPrefix("/"))
            #expect(relative.path.hasSuffix("/some/dir"))
        }

        @Test("falls back to the default for a missing or empty value")
        func invalidValue() {
            #expect(AppPaths.resolveWorkDir(arguments: ["app", "--workdir"]).path == AppPaths.defaultWorkDir.path)
            #expect(AppPaths.resolveWorkDir(arguments: ["app", "--workdir="]).path == AppPaths.defaultWorkDir.path)
            #expect(AppPaths.resolveWorkDir(arguments: ["app", "--workdir", ""]).path == AppPaths.defaultWorkDir.path)
        }

        @Test("the program name is never taken for the option, the last occurrence wins")
        func argumentHandling() {
            #expect(AppPaths.resolveWorkDir(arguments: ["--workdir=/tmp/ignored"]).path == AppPaths.defaultWorkDir.path)
            let url = AppPaths.resolveWorkDir(arguments: ["app", "--workdir=/tmp/a", "--other", "--workdir", "/tmp/b"])
            #expect(url.path == "/tmp/b")
        }

        @Test("derives every location from the working directory")
        func derivedPaths() {
            let paths = AppPaths(workDir: URL(fileURLWithPath: "/tmp/ichm-w"))
            #expect(paths.configURL.path == "/tmp/ichm-w/config.json")
            #expect(paths.playlistsDir.path == "/tmp/ichm-w/playlists")
            #expect(paths.cacheDir.path == "/tmp/ichm-w/.cache")
            #expect(paths.coverCacheURL.path == "/tmp/ichm-w/.cache/covers.sqlite")
        }
    }

    @MainActor @Suite("StableHash")
    struct StableHashTests {
        @Test("matches the FNV-1a reference values")
        func referenceValues() {
            #expect("".stableHash == 0xcbf29ce484222325)
            #expect("a".stableHash == 0xaf63dc4c8601ec8c)
            #expect("foobar".stableHash == 0x85944171f73967e8)
        }

        @Test("is deterministic and sensitive to the input")
        func deterministic() {
            #expect("Artist/Album".stableHash == "Artist/Album".stableHash)
            #expect("Artist/Album".stableHash != "artist/album".stableHash)
            #expect("日本語".stableHash == "日本語".stableHash)
        }
    }
}
