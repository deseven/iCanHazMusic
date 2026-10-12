// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

/// Downloads a release, checks it and starts the script that replaces the running app once it has quit.
///
/// Steps: download the zip next to the app (same volume, so the final move is a rename) -> look at the names in
/// the archive (nothing absolute or with `..`) -> unpack with `ditto` -> the one `.app` in there must pass the
/// strict signature check and satisfy the designated requirement of the running app (so it has to be signed by
/// the same identity) -> a shell script waits for this process to end, swaps the bundles and starts the new app.
///
/// The caller has to quit the app afterwards (`AppTermination`; Core doesn't know AppKit). The script doesn't rely
/// on that: a self-update can't be fixed by a self-update, so a bug in the app's quit path would otherwise strand
/// every user of that version (it happened in 1.0.0 and 1.1.0). If the app is still running after `QuitTimeouts`,
/// the script sends SIGTERM, then SIGKILL; that may lose the last moments of config changes and cut the sound off,
/// which beats a hung app.
enum UpdateInstaller {
    /// How long the installer script waits for the app at each step, see `installerScript`.
    struct QuitTimeouts {
        /// For the app to quit on its own (it fades the music out and flushes its writes first).
        var graceful: TimeInterval = 20
        /// After SIGTERM.
        var afterTerm: TimeInterval = 5
        /// After SIGKILL, before giving up (and leaving the installed app as it is).
        var afterKill: TimeInterval = 5
    }

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
        try installerScript().write(to: script, atomically: true, encoding: .utf8)
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

    /// The script that waits for the app to end (forcing it after `timeouts`), swaps the bundles and starts the new
    /// one with `openCommand`. Arguments: pid of the app, staged bundle, installed bundle, staging directory (removed
    /// at the end). Escalations are logged to the system log (tag `iCanHazMusic-update`), since `app.log` belongs to
    /// the process being replaced.
    ///
    /// The app is recognised by pid + start time, so a process that got the pid later is never signalled.
    static func installerScript(timeouts: QuitTimeouts = QuitTimeouts(), openCommand: String = "/usr/bin/open") -> String {
        func ticks(_ seconds: TimeInterval) -> Int { max(0, Int((seconds * 10).rounded())) }
        return """
        #!/bin/sh
        set -eu

        pid="$1"
        staged_bundle="$2"
        installed_bundle="$3"
        staging_directory="$4"

        log() { /usr/bin/logger -t iCanHazMusic-update "$1" || true; }

        started="$(/bin/ps -o lstart= -p "$pid" 2>/dev/null || true)"

        alive() {
            [ -n "$started" ] || return 1
            [ "$(/bin/ps -o lstart= -p "$pid" 2>/dev/null || true)" = "$started" ] || return 1
            case "$(/bin/ps -o stat= -p "$pid" 2>/dev/null || true)" in Z*) return 1 ;; esac
        }

        # Waits up to $1 tenths of a second for the app to end; fails if it is still running.
        wait_for_quit() {
            ticks="$1"
            while alive; do
                [ "$ticks" -gt 0 ] || return 1
                ticks=$((ticks - 1))
                sleep 0.1
            done
        }

        if ! wait_for_quit \(ticks(timeouts.graceful)); then
            log "the app (pid $pid) didn't quit, sending SIGTERM"
            if alive; then kill -TERM "$pid" 2>/dev/null || true; fi
            if ! wait_for_quit \(ticks(timeouts.afterTerm)); then
                log "the app (pid $pid) didn't quit on SIGTERM, sending SIGKILL"
                if alive; then kill -KILL "$pid" 2>/dev/null || true; fi
                if ! wait_for_quit \(ticks(timeouts.afterKill)); then
                    log "the app (pid $pid) is still running, the update is cancelled"
                    rm -rf "$staging_directory"
                    exit 1
                fi
            fi
        fi

        rm -rf "$installed_bundle"
        mv "$staged_bundle" "$installed_bundle"

        \(openCommand) "$installed_bundle"

        rm -rf "$staging_directory"
        """
    }
}
