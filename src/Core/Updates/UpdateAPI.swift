// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A version number of the form `major.minor.patch` (missing parts are 0, anything that isn't a number is ignored).
struct SemVer: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ string: String) {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        major = parts.count > 0 ? parts[0] : 0
        minor = parts.count > 1 ? parts[1] : 0
        patch = parts.count > 2 ? parts[2] : 0
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// One release as GitHub lists it (only what is needed).
struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, prerelease, assets
    }

    /// The version from the release title (`iCHM 0.4.0`), else from the tag (`0.4.0` or `v0.4.0`).
    var version: String? {
        if let name, let found = Self.firstVersion(in: name, pattern: #"(?:iCanHazMusic|iCHM)\s+v?(\d+\.\d+\.\d+)"#) {
            return found
        }
        return Self.firstVersion(in: tagName, pattern: #"^v?(\d+\.\d+\.\d+)$"#)
    }

    private static func firstVersion(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// A release that can be installed.
struct UpdateInfo: Equatable, Sendable {
    let version: String
    let releaseTitle: String
    let changelog: String
    let downloadURL: URL
}

enum UpdateError: LocalizedError {
    case busy
    case invalidGitHubResponse
    case invalidDownloadedBundle
    case invalidArchiveEntry(String)
    case missingCodeSigningInfo
    case mismatchedCodeSigningInfo
    case notAnAppBundle
    case notWritable(String)
    case processFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .busy:
            "A check for updates is already in progress."
        case .invalidGitHubResponse:
            "GitHub returned an invalid response."
        case .invalidDownloadedBundle:
            "The downloaded update does not contain a valid app bundle."
        case .invalidArchiveEntry(let entry):
            "The downloaded archive contains an unsafe entry: \(entry)"
        case .missingCodeSigningInfo:
            "A bundle is missing required code-signing information."
        case .mismatchedCodeSigningInfo:
            "The downloaded app was signed by a different identity."
        case .notAnAppBundle:
            "\(AppConstants.appName) isn't running from an app bundle, so it can't update itself."
        case .notWritable(let directory):
            "\(AppConstants.appName) can't replace itself: \(directory) is not writable for you."
        case .processFailed(let path, let status):
            "\(path) failed with status \(status)"
        }
    }
}

/// The GitHub releases API of the project and how its answer is read.
enum UpdateAPI {
    static let releasesURL = URL(string: "https://api.github.com/repos/deseven/iCanHazMusic/releases")!
    /// The asset of a release with the zipped app.
    static let assetName = "ichm.zip"
    static let timeout: TimeInterval = 30

    static func request() -> URLRequest {
        var request = URLRequest(appURL: releasesURL, timeout: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    static func releases(from answer: HTTPAnswer) throws -> [GitHubRelease] {
        guard (200..<300).contains(answer.status),
              let releases = try? JSONDecoder().decode([GitHubRelease].self, from: answer.body) else {
            throw UpdateError.invalidGitHubResponse
        }
        return releases
    }

    /// The newest stable release that has a version and the app's zip, whether it is newer than the running app
    /// or not.
    static func latest(in releases: [GitHubRelease]) -> UpdateInfo? {
        releases
            .compactMap { release -> (SemVer, UpdateInfo)? in
                guard !release.prerelease, let version = release.version,
                      let asset = release.assets.first(where: { $0.name == assetName }) else { return nil }
                let info = UpdateInfo(
                    version: version,
                    releaseTitle: release.name ?? version,
                    changelog: release.body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "No changelog available.",
                    downloadURL: asset.browserDownloadURL
                )
                return (SemVer(version), info)
            }
            .max { $0.0 < $1.0 }?
            .1
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
