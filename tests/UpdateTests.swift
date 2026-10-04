import Foundation
import Testing
@testable import iCanHazMusic

/// What GitHub answers to the releases request.
private enum GitHubAnswer {
    static func release(
        title: String?, tag: String = "x", body: String? = "notes", prerelease: Bool = false,
        assets: [String] = [UpdateAPI.assetName]
    ) -> [String: Any] {
        [
            "tag_name": tag,
            "name": title as Any? ?? NSNull(),
            "body": body as Any? ?? NSNull(),
            "prerelease": prerelease,
            "assets": assets.map { ["name": $0, "browser_download_url": "https://example.com/\(tag)/\($0)"] },
        ]
    }

    static func releases(_ releases: [[String: Any]]) -> HTTPAnswer {
        HTTPAnswer(status: 200, body: (try? JSONSerialization.data(withJSONObject: releases)) ?? Data())
    }
}

extension AllTests {
    @MainActor @Suite("Update API")
    struct UpdateAPITests {
        @Test("versions compare by number, not by text, and missing parts are 0")
        func semVer() {
            #expect(SemVer("0.10.0") > SemVer("0.9.9"))
            #expect(SemVer("1.0") == SemVer("1.0.0"))
            #expect(SemVer("0.4.0") > SemVer("0.3.1"))
            #expect(SemVer("0") < SemVer("0.0.1"))
            #expect(!(SemVer("2.0.0") < SemVer("2.0.0")))
        }

        @Test("the request asks the GitHub API for the releases of the project, as the app")
        func request() {
            let request = UpdateAPI.request()
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == "api.github.com" && request.url?.path == "/repos/deseven/iCanHazMusic/releases")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == AppConstants.userAgent)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        }

        @Test("the version comes from the title, else from the tag")
        func versionOfRelease() throws {
            func version(title: String?, tag: String) throws -> String? {
                let answer = GitHubAnswer.releases([GitHubAnswer.release(title: title, tag: tag)])
                return try UpdateAPI.releases(from: answer).first?.version
            }
            #expect(try version(title: "iCHM 0.4.0", tag: "nightly") == "0.4.0")
            #expect(try version(title: "iCanHazMusic v1.2.3", tag: "nightly") == "1.2.3")
            #expect(try version(title: "Big release", tag: "0.5.1") == "0.5.1")
            #expect(try version(title: nil, tag: "v0.5.1") == "0.5.1")
            #expect(try version(title: "Big release", tag: "latest") == nil)
        }

        @Test("the newest stable release with the app's zip wins, the order GitHub lists them in doesn't matter")
        func latest() throws {
            let releases = try UpdateAPI.releases(from: GitHubAnswer.releases([
                GitHubAnswer.release(title: "iCHM 0.3.1", tag: "0.3.1"),
                GitHubAnswer.release(title: "iCHM 0.10.0", tag: "0.10.0", body: "the notes"),
                GitHubAnswer.release(title: "iCHM 0.9.0", tag: "0.9.0"),
                GitHubAnswer.release(title: "iCHM 1.0.0", tag: "1.0.0", prerelease: true),
                GitHubAnswer.release(title: "iCHM 2.0.0", tag: "2.0.0", assets: ["ichm.dmg"]),
                GitHubAnswer.release(title: "something else", tag: "nightly"),
            ]))
            let latest = try #require(UpdateAPI.latest(in: releases))
            #expect(latest.version == "0.10.0")
            #expect(latest.releaseTitle == "iCHM 0.10.0")
            #expect(latest.changelog == "the notes")
            #expect(latest.downloadURL.absoluteString == "https://example.com/0.10.0/ichm.zip")
            #expect(UpdateAPI.latest(in: []) == nil)
        }

        @Test("a release without notes still has a text to show")
        func emptyChangelog() throws {
            for body in [nil, "", "  \n"] {
                let releases = try UpdateAPI.releases(from: GitHubAnswer.releases([
                    GitHubAnswer.release(title: "iCHM 0.4.0", body: body),
                ]))
                #expect(UpdateAPI.latest(in: releases)?.changelog == "No changelog available.")
            }
        }

        @Test("an answer that isn't a list of releases is an error")
        func invalidAnswer() {
            for answer in [
                HTTPAnswer(status: 403, body: Data("{\"message\": \"rate limit\"}".utf8)),
                HTTPAnswer(status: 200, body: Data("garbage".utf8)),
                HTTPAnswer(status: 200, body: Data("{}".utf8)),
            ] {
                #expect(throws: UpdateError.self) { try UpdateAPI.releases(from: answer) }
            }
        }

        @Test("archives with entries that leave the directory are refused")
        func archiveEntries() throws {
            try UpdateInstaller.validate(entries: ["iCanHazMusic.app/", "iCanHazMusic.app/Contents/Info.plist"])
            for entries in [[], ["/etc/passwd"], ["iCanHazMusic.app/../../evil"], ["../evil"]] {
                #expect(throws: UpdateError.self) { try UpdateInstaller.validate(entries: entries) }
            }
        }
    }

    @MainActor @Suite("Update service")
    struct UpdateServiceTests {
        private struct Env {
            let config: ConfigStore
            let transport: HTTPStub
            let service: UpdateService
        }

        private static let releases = GitHubAnswer.releases([
            GitHubAnswer.release(title: "iCHM 0.4.0", tag: "0.4.0"),
            GitHubAnswer.release(title: "iCHM 0.3.0", tag: "0.3.0"),
        ])

        private func makeEnv(
            current: String = "0.3.1", answer: HTTPAnswer = UpdateServiceTests.releases,
            initialDelay: Duration = .seconds(60), checkInterval: Duration = .seconds(60)
        ) throws -> Env {
            let dir = try TempDir()
            let config = ConfigStore(paths: AppPaths(workDir: dir.path("work")), saveDelay: .seconds(60))
            let transport = HTTPStub(always: answer)
            let service = UpdateService(configStore: config, transport: transport, currentVersion: current,
                                        initialDelay: initialDelay, checkInterval: checkInterval)
            return Env(config: config, transport: transport, service: service)
        }

        @Test("on by default, read leniently, and the setting is kept in the config")
        func setting() throws {
            #expect(AppConfig().general.checkForUpdates)
            #expect(AppConfig().general.skippedUpdate.isEmpty)
            #expect(try JSONDecoder().decode(AppConfig.self, from: Data(#"{"general": {"check_for_updates": "no"}}"#.utf8)).general.checkForUpdates)
            let off = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"general": {"check_for_updates": false}}"#.utf8))
            #expect(!off.general.checkForUpdates)

            let env = try makeEnv()
            #expect(env.service.isEnabled)
            env.service.isEnabled = false
            #expect(!env.config.config.general.checkForUpdates)
            env.service.isEnabled = true
            #expect(env.config.config.general.checkForUpdates)

            let json = String(decoding: try #require(ConfigStore.encode(AppConfig())), as: UTF8.self)
            #expect(json.contains("\"check_for_updates\" : true"))
        }

        @Test("a newer release is offered, one that isn't newer is not")
        func newer() async throws {
            let behind = try makeEnv(current: "0.3.1")
            #expect(try await behind.service.check(manual: true)?.version == "0.4.0")
            #expect(!behind.service.isChecking)
            #expect(behind.transport.requests.count == 1)

            for current in ["0.4.0", "0.4.1", "1.0.0"] {
                let env = try makeEnv(current: current)
                #expect(try await env.service.check(manual: true) == nil)
            }
            #expect(try await makeEnv(answer: GitHubAnswer.releases([])).service.check(manual: true) == nil)
        }

        @Test("the skipped version is kept in the config; only automatic checks respect it, and a newer one is offered again")
        func skipped() async throws {
            let env = try makeEnv()
            #expect(env.service.skippedVersion == nil)
            env.service.skippedVersion = "0.4.0"
            #expect(env.config.config.general.skippedUpdate == "0.4.0")

            #expect(try await env.service.check(manual: false) == nil)
            #expect(try await env.service.check(manual: true)?.version == "0.4.0")

            let newer = try makeEnv(answer: GitHubAnswer.releases([GitHubAnswer.release(title: "iCHM 0.5.0", tag: "0.5.0")]))
            newer.service.skippedVersion = "0.4.0"
            #expect(try await newer.service.check(manual: false)?.version == "0.5.0")
        }

        @Test("a failed check is an error and doesn't leave the service busy")
        func failure() async throws {
            let env = try makeEnv(answer: HTTPAnswer(status: 500, body: Data()))
            await #expect(throws: UpdateError.self) { try await env.service.check(manual: true) }
            #expect(!env.service.isChecking)

            let offline = UpdateService(configStore: nil, transport: HTTPStub { _, _ in throw URLError(.notConnectedToInternet) },
                                        currentVersion: "0.1.0")
            await #expect(throws: URLError.self) { try await offline.check(manual: true) }
            #expect(!offline.isChecking)
        }

        @Test("automatic checks start after the delay and are reported, unless turned off")
        func automatic() async throws {
            let env = try makeEnv(initialDelay: .milliseconds(10), checkInterval: .seconds(60))
            var found: [UpdateInfo] = []
            env.service.onUpdateFound = { found.append($0) }
            env.service.isEnabled = false
            env.service.start()
            try await Task.sleep(for: .milliseconds(100))
            #expect(env.transport.requests.isEmpty && found.isEmpty)

            env.service.isEnabled = true
            for _ in 0..<100 where found.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            #expect(found.map(\.version) == ["0.4.0"])
            #expect(env.transport.requests.count == 1)

            env.service.isEnabled = false
        }

        @Test("automatic checks repeat on the interval")
        func repeating() async throws {
            let env = try makeEnv(initialDelay: .zero, checkInterval: .milliseconds(20))
            var found = 0
            env.service.onUpdateFound = { _ in found += 1 }
            env.service.start()
            for _ in 0..<100 where found < 3 { try await Task.sleep(for: .milliseconds(20)) }
            env.service.isEnabled = false
            #expect(found >= 3)
        }
    }
}
