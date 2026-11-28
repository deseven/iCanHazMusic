// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Discord")
    struct DiscordTests {
        private func track(artist: String = "Artist", title: String = "Title", album: String = "Album",
                           duration: TimeInterval = 200) -> PlayedTrack {
            PlayedTrack(artist: artist, title: title, album: album, duration: duration, startedAt: Date())
        }

        // MARK: Frames

        @Test("a frame is opcode and length, little endian, then the payload")
        func frameEncoding() throws {
            let frame = DiscordIPCFrame(.frame, payload: Data("{}".utf8))
            #expect([UInt8](frame.encoded) == [1, 0, 0, 0, 2, 0, 0, 0, 0x7B, 0x7D])
        }

        @Test("frames are taken from the buffer one by one, a partial one is left for later")
        func frameTaking() throws {
            let a = DiscordIPCFrame(.ping, payload: Data("a".utf8))
            let b = DiscordIPCFrame(.frame, payload: Data("{\"x\":1}".utf8))
            let whole = a.encoded + b.encoded
            var buffer = whole.prefix(whole.count - 1)
            #expect(try DiscordIPCFrame.take(from: &buffer) == a)
            #expect(try DiscordIPCFrame.take(from: &buffer) == nil)
            buffer.append(whole.last!)
            #expect(try DiscordIPCFrame.take(from: &buffer) == b)
            #expect(buffer.isEmpty)

            var short = Data([1, 0, 0])
            #expect(try DiscordIPCFrame.take(from: &short) == nil)
            #expect(short.count == 3)
        }

        @Test("an absurd length is an error, not a wait")
        func frameMalformed() {
            var buffer = Data([1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F])
            #expect(throws: DiscordIPCFrame.Malformed.self) { try DiscordIPCFrame.take(from: &buffer) }
        }

        // MARK: Activity

        @Test("tracks without an artist or a title are not shown")
        func untagged() {
            #expect(DiscordActivity(track: track(artist: ""), position: 0, duration: 100) == nil)
            #expect(DiscordActivity(track: track(title: " "), position: 0, duration: 100) == nil)
            let noAlbum = DiscordActivity(track: track(album: ""), position: 0, duration: 100)
            #expect(noAlbum != nil)
            #expect(noAlbum?.album == nil)
        }

        @Test("start and end come from the position and the duration")
        func times() throws {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let activity = try #require(DiscordActivity(track: track(), position: 30, duration: 200, now: now))
            #expect(activity.start == now.addingTimeInterval(-30))
            #expect(activity.end == now.addingTimeInterval(170))
            let unknown = try #require(DiscordActivity(track: track(), position: 30, duration: 0, now: now))
            #expect(unknown.end == nil)
        }

        @Test("small time differences are not worth an update, other ones and other texts are")
        func closeness() throws {
            let now = Date()
            let a = try #require(DiscordActivity(track: track(), position: 10, duration: 200, now: now))
            let drifted = try #require(DiscordActivity(track: track(), position: 11.5, duration: 200, now: now))
            let seeked = try #require(DiscordActivity(track: track(), position: 60, duration: 200, now: now))
            let other = try #require(DiscordActivity(track: track(title: "Other"), position: 10, duration: 200, now: now))
            let noEnd = try #require(DiscordActivity(track: track(), position: 10, duration: 0, now: now))
            #expect(a.isClose(to: drifted))
            #expect(!a.isClose(to: seeked))
            #expect(!a.isClose(to: other))
            #expect(!a.isClose(to: noEnd))
        }

        @Test("texts are kept within Discord's limits")
        func fieldLimits() throws {
            #expect(DiscordActivity.field("  ") == nil)
            #expect(DiscordActivity.field(" X ") == "X\u{2800}")
            #expect(DiscordActivity.field("AB") == "AB")
            let long = try #require(DiscordActivity.field(String(repeating: "é", count: 300)))
            #expect(long.utf16.count <= DiscordActivity.maxLength)
            #expect(long.hasSuffix("…"))
            // Characters that take two UTF-16 units are never cut in half.
            let emoji = try #require(DiscordActivity.field(String(repeating: "🎵", count: 100)))
            #expect(emoji.utf16.count <= DiscordActivity.maxLength)
            #expect(emoji.dropLast().allSatisfy { $0 == "🎵" })
        }

        @Test("the command sets a listening activity, or clears it")
        func command() throws {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let activity = try #require(DiscordActivity(track: track(), position: 0, duration: 100, now: now))
            let json = try #require(try JSONSerialization.jsonObject(
                with: DiscordActivity.command(activity, pid: 42, nonce: "n")) as? [String: Any])
            #expect(json["cmd"] as? String == "SET_ACTIVITY")
            #expect(json["nonce"] as? String == "n")
            let args = try #require(json["args"] as? [String: Any])
            #expect(args["pid"] as? Int == 42)
            let sent = try #require(args["activity"] as? [String: Any])
            #expect(sent["type"] as? Int == 2)
            #expect(sent["status_display_type"] as? Int == 1)
            #expect(sent["details"] as? String == "Title")
            #expect(sent["state"] as? String == "Artist")
            let timestamps = try #require(sent["timestamps"] as? [String: Any])
            #expect(timestamps["start"] as? Int64 == 1_000_000_000)
            #expect(timestamps["end"] as? Int64 == 1_000_100_000)
            let assets = try #require(sent["assets"] as? [String: Any])
            #expect(assets["large_image"] as? String == DiscordActivity.imageKey)
            #expect(assets["large_text"] as? String == "Album")

            let clear = try #require(try JSONSerialization.jsonObject(
                with: DiscordActivity.command(nil, pid: 42, nonce: "n")) as? [String: Any])
            let clearArgs = try #require(clear["args"] as? [String: Any])
            #expect(clearArgs["activity"] == nil)
            #expect(clearArgs["pid"] as? Int == 42)
        }

        // MARK: Setup

        @Test("the application ID is read obfuscated from the bundle info, and only a numeric one")
        func appID() {
            let key = DiscordPresence.appIDInfoKey
            #expect(DiscordPresence.appID(fromInfo: [key: Obfuscation.obfuscated("12345")]) == "12345")
            #expect(DiscordPresence.appID(fromInfo: [key: "12345"]) == nil)
            #expect(DiscordPresence.appID(fromInfo: [key: Obfuscation.obfuscated("")]) == nil)
            #expect(DiscordPresence.appID(fromInfo: [key: Obfuscation.obfuscated("12a45")]) == nil)
            #expect(DiscordPresence.appID(fromInfo: [:]) == nil)
            #expect(DiscordPresence.appID(fromInfo: nil) == nil)
        }

        @Test("rich presence is off by default and read from the config")
        func config() throws {
            #expect(!AppConfig().integrations.discord.enabled)
            let config = try JSONDecoder().decode(AppConfig.self,
                                                  from: Data(#"{"integrations": {"discord": {"enabled": true}}}"#.utf8))
            #expect(config.integrations.discord.enabled)
            #expect(!config.integrations.lrclib.enabled)
        }

        @Test("the socket is looked for in the temporary directories, each path once")
        func socketPaths() {
            let paths = DiscordIPCConnection.socketPaths(environment: ["TMPDIR": "/tmp/", "TMP": "/x"])
            #expect(paths.first == "/tmp/discord-ipc-0")
            #expect(paths.contains("/x/discord-ipc-9"))
            #expect(paths.count == Set(paths).count)
        }

        // MARK: Connection

        @Test("connects with a handshake, sends commands, answers pings and notices the end")
        func connection() async throws {
            let server = try FakeDiscordServer(answer: .ready)
            defer { server.stop() }
            let lost = LostFlag()
            let connection = DiscordIPCConnection(paths: ["/nonexistent/discord-ipc-0", server.path]) { lost.set($0) }

            try await connection.open(clientID: "12345")
            let handshake = try #require(await server.frames(count: 1).first)
            #expect(handshake.opcode == DiscordIPCFrame.Opcode.handshake.rawValue)
            #expect(handshake.json?["client_id"] as? String == "12345")
            #expect(handshake.json?["v"] as? Int == 1)

            #expect(await connection.send(DiscordActivity.command(nil, pid: 1, nonce: "a")))
            let command = try #require(await server.frames(count: 2).last)
            #expect(command.opcode == DiscordIPCFrame.Opcode.frame.rawValue)
            #expect(command.json?["cmd"] as? String == "SET_ACTIVITY")

            server.send(DiscordIPCFrame(.ping, payload: Data("{\"p\":1}".utf8)))
            let pong = try #require(await server.frames(count: 3).last)
            #expect(pong.opcode == DiscordIPCFrame.Opcode.pong.rawValue)
            #expect(pong.payload == Data("{\"p\":1}".utf8))

            server.disconnectClient()
            #expect(await lost.wait() != nil)
            #expect(await !connection.send(Data("{}".utf8)))
        }

        @Test("a rejected handshake and a missing Discord are errors")
        func failures() async throws {
            let server = try FakeDiscordServer(answer: .reject)
            defer { server.stop() }
            let rejected = DiscordIPCConnection(paths: [server.path]) { _ in }
            await #expect(throws: DiscordIPCConnection.Failure.self) { try await rejected.open(clientID: "1") }

            let missing = DiscordIPCConnection(paths: ["/nonexistent/discord-ipc-0"]) { _ in }
            await #expect(throws: DiscordIPCConnection.Failure.self) { try await missing.open(clientID: "1") }
        }
    }
}

/// Remembers the reason of `onLost`.
private final class LostFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?

    func set(_ reason: String) { lock.withLock { self.reason = reason } }

    func wait(timeout: TimeInterval = 3) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reason = lock.withLock({ reason }) { return reason }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

/// A stand-in for the Discord client: a Unix socket that takes one connection, answers the handshake and records
/// every frame it gets.
private final class FakeDiscordServer: @unchecked Sendable {
    enum Answer { case ready, reject }

    let path = "/tmp/ichm-discord-test-\(UUID().uuidString.prefix(8))"
    private let answer: Answer
    private let queue = DispatchQueue(label: "fake-discord")
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var received: [DiscordIPCFrame] = []

    init(answer: Answer) throws {
        self.answer = answer
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        queue.async { self.serve() }
    }

    private func serve() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        lock.withLock { client = fd }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let frame = try? DiscordIPCFrame.take(from: &buffer) {
                lock.withLock { received.append(frame) }
                if frame.opcode == DiscordIPCFrame.Opcode.handshake.rawValue { answerHandshake() }
            }
        }
    }

    private func answerHandshake() {
        switch answer {
        case .ready:
            send(DiscordIPCFrame(.frame, payload: Data(#"{"cmd":"DISPATCH","evt":"READY","data":{"v":1}}"#.utf8)))
        case .reject:
            send(DiscordIPCFrame(.close, payload: Data(#"{"code":4000,"message":"Invalid Client ID"}"#.utf8)))
        }
    }

    func send(_ frame: DiscordIPCFrame) {
        let fd = lock.withLock { client }
        guard fd >= 0 else { return }
        let data = frame.encoded
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Waits until at least `count` frames came in; all of them.
    func frames(count: Int, timeout: TimeInterval = 3) async -> [DiscordIPCFrame] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frames = lock.withLock { received }
            if frames.count >= count { return frames }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return lock.withLock { received }
    }

    func disconnectClient() {
        let fd = lock.withLock { client }
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    func stop() {
        disconnectClient()
        lock.withLock {
            if client >= 0 { close(client) }
            client = -1
        }
        close(listener)
        unlink(path)
    }
}
