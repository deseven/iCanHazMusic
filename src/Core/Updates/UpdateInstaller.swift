import Foundation
import Security

/// Downloads a release, checks it and starts the script that replaces the running app once it has quit.
///
/// Steps: download the zip next to the app (same volume, so the final move is a rename) -> look at the names in
/// the archive (nothing absolute or with `..`) -> unpack with `ditto` -> the one `.app` in there must pass the
/// strict signature check and satisfy the designated requirement of the running app (so it has to be signed by
/// the same identity) -> a shell script waits for this process to end, swaps the bundles and starts the new app.
///
/// The caller has to quit the app afterwards (`NSApp.terminate`; Core doesn't know AppKit).
enum UpdateInstaller {
    /// How long the script waits for the app to quit before it gives up.
    private static let quitDeadlineSeconds = 300

    static func install(_ info: UpdateInfo, installedBundle: URL = Bundle.main.bundleURL) async throws {
        guard installedBundle.pathExtension == "app" else { throw UpdateError.notAnAppBundle }
        let parent = installedBundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }

        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: installedBundle,
            create: true
        )
        do {
            try await stageAndLaunch(info, installedBundle: installedBundle, staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func stageAndLaunch(_ info: UpdateInfo, installedBundle: URL, staging: URL) async throws {
        Log.info("updates: downloading v\(info.version) from \(info.downloadURL.absoluteString)")
        let archive = staging.appendingPathComponent(UpdateAPI.assetName)
        try await download(info.downloadURL, to: archive)

        let entries = try await run("/usr/bin/unzip", ["-Z", "-1", archive.path])
            .split(whereSeparator: \.isNewline).map(String.init)
        try validate(entries: entries)

        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try await run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])

        let stagedBundle = try findAppBundle(in: extracted)
        guard Bundle(url: stagedBundle)?.executableURL != nil else { throw UpdateError.invalidDownloadedBundle }
        try verifySignature(current: installedBundle, candidate: stagedBundle)

        let script = staging.appendingPathComponent("install-update.sh")
        try installerScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = script
        process.arguments = ["\(getpid())", stagedBundle.path, installedBundle.path, staging.path]
        try process.run()
        Log.info("updates: v\(info.version) is ready, the installer waits for the app to quit")
    }

    // MARK: - Download

    private static func download(_ url: URL, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = UpdateAPI.timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (file, response) = try await session.download(for: URLRequest(appURL: url, timeout: UpdateAPI.timeout))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.invalidGitHubResponse
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    // MARK: - Archive

    static func validate(entries: [String]) throws {
        guard !entries.isEmpty else { throw UpdateError.invalidDownloadedBundle }
        for entry in entries {
            let components = entry.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/")
            guard !entry.hasPrefix("/"), !components.contains("..") else {
                throw UpdateError.invalidArchiveEntry(entry)
            }
        }
    }

    private static func findAppBundle(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let apps = try contents.filter { url in
            guard url.pathExtension == "app" else { return false }
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        guard apps.count == 1, let app = apps.first else { throw UpdateError.invalidDownloadedBundle }
        return app
    }

    // MARK: - Code signature

    private static func verifySignature(current: URL, candidate: URL) throws {
        let currentCode = try staticCode(at: current)
        let candidateCode = try staticCode(at: candidate)
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)

        guard SecStaticCodeCheckValidityWithErrors(currentCode, flags, nil, nil) == errSecSuccess else {
            throw UpdateError.missingCodeSigningInfo
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(currentCode, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError.missingCodeSigningInfo
        }
        guard SecStaticCodeCheckValidityWithErrors(candidateCode, flags, requirement, nil) == errSecSuccess else {
            throw UpdateError.mismatchedCodeSigningInfo
        }
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else {
            throw UpdateError.missingCodeSigningInfo
        }
        return code
    }

    // MARK: - Processes

    /// Runs a tool and returns what it printed; its errors are dropped.
    private static func run(_ path: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Read before waiting: a full pipe would block the tool.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw UpdateError.processFailed(path, process.terminationStatus) }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// Arguments: pid of the app, staged bundle, installed bundle, staging directory (removed at the end).
    private static let installerScript = """
    #!/bin/sh
    set -eu

    pid="$1"
    staged_bundle="$2"
    installed_bundle="$3"
    staging_directory="$4"
    deadline=$(( $(date +%s) + \(quitDeadlineSeconds) ))

    while kill -0 "$pid" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            rm -rf "$staging_directory"
            exit 1
        fi
        sleep 0.2
    done

    rm -rf "$installed_bundle"
    mv "$staged_bundle" "$installed_bundle"

    /usr/bin/open "$installed_bundle"

    rm -rf "$staging_directory"
    """
}
