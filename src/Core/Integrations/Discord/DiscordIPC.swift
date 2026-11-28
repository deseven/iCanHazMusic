// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One message of Discord's local IPC protocol: opcode (UInt32, little endian), payload length (UInt32, little
/// endian), JSON payload.
struct DiscordIPCFrame: Equatable {
    enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    /// Payloads bigger than this are taken as garbage (Discord's are a few KB at most).
    static let maxPayload = 1 << 20
    static let headerSize = 8

    var opcode: UInt32
    var payload: Data

    init(_ opcode: Opcode, payload: Data) {
        self.opcode = opcode.rawValue
        self.payload = payload
    }

    init(opcode: UInt32, payload: Data) {
        self.opcode = opcode
        self.payload = payload
    }

    var encoded: Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        for value in [opcode, UInt32(payload.count)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    struct Malformed: Error {}

    /// Removes the first complete frame from the start of `buffer`; nil (and `buffer` untouched) while it isn't all
    /// there yet. Throws for a length no frame can have: the stream is then out of step and can't be read on.
    static func take(from buffer: inout Data) throws -> DiscordIPCFrame? {
        guard buffer.count >= headerSize else { return nil }
        let bytes = [UInt8](buffer.prefix(headerSize))
        func uint32(at offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        let length = Int(uint32(at: 4))
        guard length <= maxPayload else { throw Malformed() }
        guard buffer.count >= headerSize + length else { return nil }
        let start = buffer.startIndex + headerSize
        let frame = DiscordIPCFrame(opcode: uint32(at: 0), payload: Data(buffer[start..<start + length]))
        buffer = Data(buffer[(start + length)...])
        return frame
    }

    /// The payload as a JSON object, if it is one.
    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
}

/// A connection to the Discord desktop client through its IPC socket (`discord-ipc-{0...9}` in the temporary
/// directory), unauthenticated: the handshake with the application ID is enough to set the activity.
///
/// All the work (blocking socket calls, bounded by timeouts) is done on a serial queue of its own; the `async`
/// methods wait for it without holding a thread of the caller. `onLost` is called (on that queue) when an open
/// connection ends without `close()`: Discord quit, closed it, or sent something that can't be read.
final class DiscordIPCConnection: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        /// No socket that accepts a connection: Discord isn't running (or is a sandboxed build that has its socket
        /// somewhere else).
        case notRunning
        /// Connected, but the handshake failed (`message` from Discord, or what went wrong).
        case handshake(String)

        var description: String {
            switch self {
            case .notRunning: "Discord is not running"
            case .handshake(let message): "handshake failed: \(message)"
            }
        }
    }

    /// Socket read/write timeout, and how long the handshake may take as a whole.
    static let timeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "wtf.d7.icanhazmusic.discord-ipc")
    private let paths: [String]
    private let onLost: @Sendable (String) -> Void
    // Touched only on `queue`.
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var isClosed = false

    /// `paths`: where to look for the socket (the first one that takes the connection is used).
    init(paths: [String] = DiscordIPCConnection.socketPaths(), onLost: @escaping @Sendable (String) -> Void) {
        self.paths = paths
        self.onLost = onLost
    }

    deinit {
        if let source { source.cancel() } else if fd >= 0 { Darwin.close(fd) }
    }

    /// The paths Discord may listen on, in the order its own libraries try them.
    static func socketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var dirs: [String] = []
        for key in ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"] {
            if let dir = environment[key], !dir.isEmpty { dirs.append(dir) }
        }
        dirs.append(NSTemporaryDirectory())
        dirs.append("/tmp")
        var seen = Set<String>()
        var paths: [String] = []
        for dir in dirs {
            let base = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
            guard seen.insert(base).inserted else { continue }
            paths += (0..<10).map { "\(base)/discord-ipc-\($0)" }
        }
        return paths
    }

    /// Connects and does the handshake. Called once.
    func open(clientID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.openOnQueue(clientID: clientID)
                    continuation.resume()
                } catch {
                    self.shutDown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sends a command (a JSON object); false if the connection is gone (`onLost` has been called then).
    func send(_ payload: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.isClosed, self.fd >= 0 else { return continuation.resume(returning: false) }
                do {
                    try self.write(DiscordIPCFrame(.frame, payload: payload))
                    continuation.resume(returning: true)
                } catch {
                    self.lose("write failed: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Closes the connection (Discord clears the activity then). `onLost` isn't called.
    func close() {
        queue.async {
            guard !self.isClosed else { return }
            if self.fd >= 0 { try? self.write(DiscordIPCFrame(.close, payload: Data("{}".utf8))) }
            self.shutDown()
        }
    }

    // MARK: - On the queue

    private struct SystemError: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    private func openOnQueue(clientID: String) throws {
        fd = try connectToFirstSocket()
        let handshake = try JSONSerialization.data(withJSONObject: ["v": 1, "client_id": clientID])
        try write(DiscordIPCFrame(.handshake, payload: handshake))

        // The answer is a READY dispatch, or a CLOSE with the reason (an unknown application ID, for one).
        let deadline = Date().addingTimeInterval(Self.timeout)
        while true {
            guard Date() < deadline else { throw Failure.handshake("no answer") }
            guard let frame = try readFrame() else { throw Failure.handshake("connection closed") }
            switch DiscordIPCFrame.Opcode(rawValue: frame.opcode) {
            case .frame?:
                let json = frame.json
                if json?["evt"] as? String == "READY" {
                    startReading()
                    return
                }
                if json?["evt"] as? String == "ERROR" { throw Failure.handshake(Self.message(of: json)) }
            case .close?:
                throw Failure.handshake(Self.message(of: frame.json))
            case .ping?:
                try write(DiscordIPCFrame(.pong, payload: frame.payload))
            default:
                break
            }
        }
    }

    private static func message(of json: [String: Any]?) -> String {
        let data = json?["data"] as? [String: Any] ?? json
        let message = data?["message"] as? String ?? "unknown error"
        if let code = data?["code"] { return "\(message) (\(code))" }
        return message
    }

    private func connectToFirstSocket() throws -> Int32 {
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let fd = try? Self.connect(to: path) { return fd }
        }
        throw Failure.notRunning
    }

    private static func connect(to path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SystemError(call: "socket path", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SystemError(call: "socket", code: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Int(Self.timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SystemError(call: "connect", code: code)
        }
        return fd
    }

    private func write(_ frame: DiscordIPCFrame) throws {
        let data = frame.encoded
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SystemError(call: "write", code: errno)
                }
                offset += written
            }
        }
    }

    /// Reads until a whole frame is there (blocking, up to the socket timeout per read); nil at the end of the stream.
    private func readFrame() throws -> DiscordIPCFrame? {
        while true {
            if let frame = try DiscordIPCFrame.take(from: &buffer) { return frame }
            guard try readAvailable() else { return nil }
        }
    }

    /// Appends what one `read` gives to `buffer`; false at the end of the stream.
    private func readAvailable() throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw SystemError(call: "read", code: errno)
            }
            if count == 0 { return false }
            buffer.append(contentsOf: chunk[0..<count])
            return true
        }
    }

    /// From now on what Discord sends is read as it arrives: answers to pings, errors of commands, the end.
    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        source.setEventHandler { [weak self] in self?.readIncoming() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    private func readIncoming() {
        guard !isClosed else { return }
        do {
            guard try readAvailable() else { return lose("closed by Discord") }
            while let frame = try DiscordIPCFrame.take(from: &buffer) {
                switch DiscordIPCFrame.Opcode(rawValue: frame.opcode) {
                case .ping?:
                    try write(DiscordIPCFrame(.pong, payload: frame.payload))
                case .close?:
                    return lose("closed by Discord: \(Self.message(of: frame.json))")
                case .frame?:
                    if let json = frame.json, json["evt"] as? String == "ERROR" {
                        Log.error("discord: \(json["cmd"] as? String ?? "command") failed: \(Self.message(of: json))")
                    }
                default:
                    break
                }
            }
        } catch {
            lose("\(error)")
        }
    }

    private func lose(_ reason: String) {
        guard !isClosed else { return }
        shutDown()
        onLost(reason)
    }

    private func shutDown() {
        isClosed = true
        if let source {
            source.cancel()   // closes the descriptor
            self.source = nil
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        fd = -1
        buffer = Data()
    }
}
