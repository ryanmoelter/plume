import Foundation

/// What a command-mode command did: what it printed on each stream, and how
/// it ended.
nonisolated struct CommandModeResult: Equatable, Sendable {
    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int32

    /// The user turn sent to the agent, tagged as the CLI's own bash mode
    /// writes it rather than as prose.
    ///
    /// Claude Code records the command and its output as two transcript
    /// lines, but both carry one `promptId` and the reply comes only after
    /// the second — so they are one prompt, and go as one message here.
    /// Sending them as two would start a turn on the command alone and let
    /// the agent answer before its output existed.
    ///
    /// Matching the tags is what makes the agent read this the way it reads
    /// its own bash mode, and `InjectedContent` classifies the same tags, so
    /// the chat renders it as a shell marker rather than words the user
    /// typed. Both output tags are always written, empty or not, as the CLI
    /// does. The exit code has no tag of its own and is left out: a failing
    /// command explains itself through stderr.
    var transcriptText: String {
        """
        <bash-input>\(command)</bash-input>
        <bash-stdout>\(stdout)</bash-stdout><bash-stderr>\(stderr)</bash-stderr>
        """
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
                stdout: "",
                stderr: launchError.localizedDescription,
                exitCode: -1
            )
        }

        // Read before waiting: a pipe that fills up would deadlock the child.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandModeResult(
            command: command,
            stdout: truncated(text(outputData)),
            stderr: truncated(text(errorData)),
            exitCode: process.terminationStatus
        )
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
