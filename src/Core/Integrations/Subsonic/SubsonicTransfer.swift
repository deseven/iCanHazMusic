// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Downloads one URL into a file, as it comes (never the whole thing in memory), for the files of `SubsonicDownloads`.
///
/// - The request is given up on when nothing arrives for `idleTimeout` seconds; a download that keeps going is not
///   limited (a hi-res album track over a slow line takes minutes), only by `totalTimeout`, which is just a safety net.
/// - The server answers an error with a normal-looking response whose body is the error (`download` of a song that is gone
///   is a 200 with a JSON `failed`): a body that is not audio (text, JSON, XML, or any status but 200) is read as an
///   answer and turned into the error it stands for (`SubsonicAPI.parse`) instead of being saved as a file.
/// - A download that ends short of what the server announced, or fails half way, is an error and leaves no file.
/// - Throws `CancellationError` when the task is cancelled (the transfer stops at once), `SubsonicError` for everything
///   else: `.connection` for what may work on the other address.
/// - `progress` is told how many bytes of the file have been written and how many there will be (nil: the server didn't
///   say), from the session's queue, as the data comes.
enum SubsonicTransfer {
    typealias Progress = @Sendable (_ received: Int64, _ expected: Int64?) -> Void

    static let idleTimeout: TimeInterval = 30
    static let totalTimeout: TimeInterval = 6 * 3600

    static func download(from url: URL, to file: URL, progress: @escaping Progress = { _, _ in }) async throws {
        try await FileTransfer(file: file, progress: progress).run(URLRequest(appURL: url, timeout: idleTimeout))
    }
}

private final class FileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// How much of an error body is read.
    private static let maxErrorBody = 64 * 1024

    private let file: URL
    private let progress: SubsonicTransfer.Progress
    /// Guards everything below: the task, the delegate's queue and `cancel` all touch it.
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var response: HTTPURLResponse?
    private var errorBody = Data()
    private var isErrorBody = false
    private var received: Int64 = 0
    private var writeError: Error?
    private var cancelled = false

    init(file: URL, progress: @escaping SubsonicTransfer.Progress) {
        self.file = file
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = SubsonicTransfer.idleTimeout
                configuration.timeoutIntervalForResource = SubsonicTransfer.totalTimeout
                configuration.waitsForConnectivity = false
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.continuation = continuation
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let error = (http?.statusCode ?? 200) != 200 || type.hasPrefix("text/") || type.contains("json") || type.contains("xml")

        lock.lock()
        self.response = http
        isErrorBody = error
        lock.unlock()

        if !error {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: file)
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                    throw SubsonicError(.rejected, "can't create \(file.lastPathComponent)")
                }
                let opened = try FileHandle(forWritingTo: file)
                lock.lock()
                handle = opened
                lock.unlock()
            } catch {
                lock.lock()
                writeError = error
                lock.unlock()
                completionHandler(.cancel)
                return
            }
            // The size is known from here on, so the ring can be drawn empty before the first bytes arrive.
            if let expected = http?.expectedContentLength, expected > 0 { progress(0, expected) }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if isErrorBody {
            if errorBody.count < Self.maxErrorBody { errorBody.append(data.prefix(Self.maxErrorBody - errorBody.count)) }
            lock.unlock()
            return
        }
        let handle = self.handle
        lock.unlock()
        do {
            try handle?.write(contentsOf: data)
            lock.lock()
            received += Int64(data.count)
            let (total, expected) = (received, response?.expectedContentLength)
            lock.unlock()
            progress(total, expected.flatMap { $0 > 0 ? $0 : nil })
        } catch {
            lock.lock()
            writeError = error
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let handle = self.handle
        self.handle = nil
        let (response, body, isErrorBody, received, writeError, cancelled) =
            (self.response, errorBody, self.isErrorBody, self.received, self.writeError, self.cancelled)
        lock.unlock()

        try? handle?.close()
        session.finishTasksAndInvalidate()

        let failure: Error? = {
            if let writeError {
                return SubsonicError(.rejected, "can't save the file: \(writeError.localizedDescription)")
            }
            if cancelled || (error as? URLError)?.code == .cancelled { return CancellationError() }
            if let error { return SubsonicError(.connection, error.localizedDescription) }
            if isErrorBody {
                do {
                    _ = try SubsonicAPI.parse(status: response?.statusCode ?? 0, body: body)
                    return SubsonicError(.rejected, "the server didn't send the file")
                } catch {
                    return error
                }
            }
            if let expected = response?.expectedContentLength, expected > 0, received != expected {
                return SubsonicError(.connection, "the download broke off after \(received) of \(expected) bytes")
            }
            return nil
        }()

        if failure != nil { try? FileManager.default.removeItem(at: file) }
        if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}
