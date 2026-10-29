import Foundation

/// A command that can't go on. The dispatcher prints `<prog>: <message>` to
/// stderr and exits with `code`. A nil message exits silently, for a child
/// process whose own error output already reached the terminal.
nonisolated struct CLIFailure: Error, Equatable, Sendable {
    var message: String?
    var code: Int32

    init(_ message: String?, code: Int32 = 1) {
        self.message = message
        self.code = code
    }
}

nonisolated struct CLIProcessResult: Equatable, Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs subprocesses for the git and forge layers.
nonisolated enum CLIProcess {
    /// Runs `arguments`, resolving the executable on PATH.
    ///
    /// With `capture` off, the child shares this process's stdout and stderr,
    /// for git output the user should see. With `check` on, a non-zero exit
    /// throws a `CLIFailure` naming the command and its trimmed stderr.
    @discardableResult
    static func run(
        _ arguments: [String],
        check: Bool = true,
        capture: Bool = true,
        input: String? = nil,
        workingDirectory: String? = nil
    ) throws -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let stdinPipe = input.map { _ in Pipe() }
        if let stdinPipe { process.standardInput = stdinPipe }
        let outputPipe = capture ? Pipe() : nil
        let errorPipe = capture ? Pipe() : nil
        if let outputPipe { process.standardOutput = outputPipe }
        if let errorPipe { process.standardError = errorPipe }

        // `waitUntilExit` polls a run loop and adds tens of milliseconds to
        // every child, which `wt list`'s many git calls add up.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw CLIFailure("`\(arguments.joined(separator: " "))` failed: \(error.localizedDescription)")
        }

        if let stdinPipe, let input {
            let handle = stdinPipe.fileHandleForWriting
            Thread {
                try? handle.write(contentsOf: Data(input.utf8))
                try? handle.close()
            }.start()
        }

        // Drain stderr concurrently: a child that fills either pipe while
        // the other is being read would deadlock. On its own thread rather
        // than a dispatch queue, because the callers block while they wait,
        // and enough of them in parallel starve the queue of threads.
        let errorData = DataBox()
        let errorRead = DispatchGroup()
        if let errorPipe {
            errorRead.enter()
            Thread {
                errorData.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                errorRead.leave()
            }.start()
        }
        let outputData = outputPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        errorRead.wait()
        exited.wait()

        let result = CLIProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData.data, as: UTF8.self)
        )
        if check, result.status != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIFailure("`\(arguments.joined(separator: " "))` failed" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return result
    }

    /// The absolute path `name` resolves to on PATH, or nil.
    static func which(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Written once by the reader thread, read after `DispatchGroup.wait`.
private nonisolated final class DataBox: @unchecked Sendable {
    var data = Data()
}
