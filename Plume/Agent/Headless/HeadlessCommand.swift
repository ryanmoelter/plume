import Foundation

/// Builds the argv for a headless `claude` run.
///
/// A real argument array rather than a shell string, so nothing needs quoting
/// here. `HeadlessProcess` quotes and wraps it in a login shell, which is what
/// puts `claude` on PATH.
enum HeadlessCommand {
    static func arguments(
        resumeSessionID: String?,
        permissionMode: PermissionMode?,
        settingsPath: String?
    ) -> [String] {
        var arguments = [
            "claude",
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            // Without this a headless run never asks: a tool needing approval
            // is auto-denied and the turn ends having done nothing.
            "--permission-prompt-tool", "stdio"
        ]

        // A `-p` session starts in Manual on every plan, so a mode is always
        // passed rather than left to the CLI's default. `permissionMode` is
        // expected to already be resolved (task override, or the user's
        // configured default); `.acceptEdits` here is only a last-resort
        // floor for when even that resolution comes back empty, not Plume's
        // preferred mode.
        arguments.append("--permission-mode")
        arguments.append((permissionMode ?? .acceptEdits).token)

        if let settingsPath {
            arguments.append("--settings")
            arguments.append(settingsPath)
        }
        if let resumeSessionID, !resumeSessionID.isEmpty {
            arguments.append("--resume")
            arguments.append(resumeSessionID)
        }
        return arguments
    }

    /// Renders argv as one login-shell command line, quoting each argument so
    /// spaces and JSON punctuation survive the trip through the shell.
    static func loginShellCommand(arguments: [String]) -> String {
        LoginShellCommand.wrap(arguments.map(shellQuoted).joined(separator: " "))
    }
}
