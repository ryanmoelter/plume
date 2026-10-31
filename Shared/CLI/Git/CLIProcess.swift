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

typealias CLIProcessResult = ChildProcessResult

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
        let result: CLIProcessResult
        do {
            // In this process's group, so a git that opens an editor can still read the terminal.
            result = try ChildProcess.run(
                executable: "/usr/bin/env",
                arguments: arguments,
                workingDirectory: workingDirectory,
                input: input.map { .text($0) } ?? .inherit,
                output: capture ? .pipes : .inherit,
                newProcessGroup: false
            )
        } catch {
            throw CLIFailure("`\(arguments.joined(separator: " "))` failed: \(error.localizedDescription)")
        }
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
