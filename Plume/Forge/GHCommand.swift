import Foundation
import Synchronization

/// Runs one `gh` invocation and returns its stdout. The synchronous form
/// blocks the calling thread, so callers reach it from an actor or a detached
/// task; the async form kills `gh` when its task is cancelled.
nonisolated enum GHCommand {
    static func run(arguments: [String], in directory: String, timeout: Duration) throws -> Data {
        try run(command: ["gh"] + arguments, in: directory, timeout: timeout, cancellation: nil)
    }

    static func run(arguments: [String], in directory: String, timeout: Duration) async throws -> Data {
        try await run(command: ["gh"] + arguments, in: directory, timeout: timeout)
    }

    /// `command` is the whole argument vector, so tests can run something
    /// other than `gh`.
    static func run(command: [String], in directory: String, timeout: Duration) async throws -> Data {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try run(command: command, in: directory, timeout: timeout, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// The running process group, so a cancel from any thread can kill it.
    private final class Cancellation: Sendable {
        private struct State {
            var processIdentifier: pid_t?
            var isCancelled = false
        }

        private let state = Mutex(State())

        var isCancelled: Bool { state.withLock { $0.isCancelled } }

        func cancel() {
            let processIdentifier = state.withLock { state in
                state.isCancelled = true
                return state.processIdentifier
            }
            if let processIdentifier { kill(-processIdentifier, SIGKILL) }
        }

        /// Records a launched process, killing it at once if the cancel came
        /// first.
        func started(_ processIdentifier: pid_t) {
            let isCancelled = state.withLock { state in
                state.processIdentifier = processIdentifier
                return state.isCancelled
            }
            if isCancelled { kill(-processIdentifier, SIGKILL) }
        }

        func finished() {
            state.withLock { $0.processIdentifier = nil }
        }
    }

    private static func run(
        command arguments: [String],
        in directory: String,
        timeout: Duration,
        cancellation: Cancellation?
    ) throws -> Data {
        let command = arguments.map(shellQuoted).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A GUI-launched app inherits no shell PATH, and `gh` lives outside
        // the system directories, so it is only reachable through a login
        // shell.
        //
        // `-m` (job control) is what makes the timeout work. Without it the
        // login shell's children join Plume's own process group, so killing
        // the shell leaves `gh` alive holding the pipe's write end — the read
        // then blocks until `gh` finishes on its own, and the deadline buys
        // nothing. With it the child leads its own group, and `kill(-pid)`
        // reaps the whole tree.
        process.arguments = ["-mc", LoginShellCommand.wrap("exec " + command)]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw ForgeError(message: "could not run gh: \(error.localizedDescription)")
        }
        cancellation?.started(process.processIdentifier)
        defer { cancellation?.finished() }

        let timedOut = Mutex(false)
        let deadline = DispatchWorkItem { [processIdentifier = process.processIdentifier] in
            timedOut.withLock { $0 = true }
            kill(-processIdentifier, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds, execute: deadline)
        defer { deadline.cancel() }

        // Read both pipes before waiting: a full pipe deadlocks the child,
        // and a rollup for a busy repo is far bigger than a pipe buffer.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if cancellation?.isCancelled == true { throw CancellationError() }
        if timedOut.withLock({ $0 }) {
            throw ForgeError(message: "gh timed out", kind: .timedOut)
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ForgeError(message: stderr.isEmpty
                ? "gh exited \(process.terminationStatus)"
                : stderr)
        }
        return outputData
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
