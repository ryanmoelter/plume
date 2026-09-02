import Foundation

/// Builds the argv for a headless `claude` run.
///
/// Unlike the TUI path this is a real argument array, not a shell string, so
/// nothing needs quoting and no login shell wraps it. `/usr/bin/env` still
/// resolves `claude` from PATH.
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
        // passed rather than left to the CLI's default.
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
}
