import Foundation
import os

/// Owns one `claude -p` subprocess and frames NDJSON in both directions.
///
/// Deliberately knows nothing about chat, status, or permissions: it delivers
/// decoded messages and writes lines back. `HeadlessSession` supplies meaning.
final class HeadlessProcess: @unchecked Sendable {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let queue = DispatchQueue(label: "com.ryanmoelter.Plume.headless")

    /// Partial trailing line carried between reads: a pipe read can split a
    /// JSON line anywhere, and a half line decodes to nothing.
    private var buffer = Data()
    private var isRunning = false

    private let onMessage: @Sendable (StreamJSONMessage) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(
        onMessage: @escaping @Sendable (StreamJSONMessage) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.onMessage = onMessage
        self.onExit = onExit
    }

    func start(arguments: [String], workingDirectory: String?, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env

        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { Log.agent.error("claude stderr: \(text, privacy: .public)") }
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(status: process.terminationStatus)
        }

        try process.run()
        queue.sync { isRunning = true }
    }

    /// Writes one NDJSON line. Silently drops the write once the process has
    /// exited — a send racing a crash is expected, not an error worth showing.
    func send(line: String) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            do {
                try self.inPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                Log.agent.error("Headless write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Ends the process. Prefer an `interrupt` control request to stop a turn;
    /// this tears the whole session down.
    func terminate() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? inPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                guard let message = StreamJSONDecoder.decode(line: line) else { continue }
                self.onMessage(message)
            }
        }
    }

    private func finish(status: Int32) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            self.onExit(status)
        }
    }
}
