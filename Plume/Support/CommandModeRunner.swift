import Foundation

/// What a command-mode command did: its output and how it ended.
nonisolated struct CommandModeResult: Equatable, Sendable {
    let command: String
    let output: String
    let exitCode: Int32

    /// The user turn sent to the agent — the command, then what it printed,
    /// so the agent sees both rather than output with no cause.
    ///
    /// Fenced because output is rarely valid markdown; a bare paste of
    /// `ls -l` reflows into a paragraph.
    var transcriptText: String {
        var lines = ["!\(command)", "", "```", output.isEmpty ? "(no output)" : output, "```"]
        if exitCode != 0 {
            lines.append("")
            lines.append("exit \(exitCode)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs a command-mode command and captures what it printed.
///
/// Separate from `GitRunner`, which throws on a nonzero exit and blocks its
/// thread. Neither suits an arbitrary user command: a failure is a normal
/// outcome whose exit code the agent should see, and the wait happens on the
/// send path.
nonisolated enum CommandModeRunner {
    /// Output past this is elided. A single `!find /` would otherwise spend
    /// the conversation's whole context on one command.
    static let maximumOutputLines = 100
    static let maximumOutputBytes = 20_000

    static func run(_ command: String, in directory: String?) async -> CommandModeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSynchronously(command, in: directory))
            }
        }
    }

    private static func runSynchronously(_ command: String, in directory: String?) -> CommandModeResult {
        let process = Process()
        // A GUI-launched app inherits no shell PATH, so the command runs in a
        // login shell. Non-interactive, unlike a terminal tab's: `.zshrc`
        // warnings would otherwise be captured as part of every result.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", LoginShellCommand.wrapNonInteractive(command)]
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        process.environment = ProcessInfo.processInfo.environment
            .merging(LoginShellCommand.plumeEnvironment) { _, override in override }

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch let launchError {
            return CommandModeResult(
                command: command,
                output: launchError.localizedDescription,
                exitCode: -1
            )
        }

        // Read before waiting: a pipe that fills up would deadlock the child.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let combined = [outputData, errorData]
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return CommandModeResult(
            command: command,
            output: truncated(combined),
            exitCode: process.terminationStatus
        )
    }

    /// Caps output by lines and by bytes, since either alone lets the other
    /// through — a thousand short lines, or one enormous one.
    static func truncated(_ output: String) -> String {
        var result = output
        var didElide = false

        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maximumOutputLines {
            result = lines.prefix(maximumOutputLines).joined(separator: "\n")
            didElide = true
        }
        if result.utf8.count > maximumOutputBytes {
            result = String(decoding: Array(result.utf8.prefix(maximumOutputBytes)), as: UTF8.self)
            didElide = true
        }
        return didElide ? result + "\n…output truncated" : result
    }
}
