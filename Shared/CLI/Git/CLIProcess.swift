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
        // TODO(PLUME-316 group A)
        CLIProcessResult(status: -1, stdout: "", stderr: "")
    }

    /// The absolute path `name` resolves to on PATH, or nil.
    static func which(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        // TODO(PLUME-316 group A)
        nil
    }
}
