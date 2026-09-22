import Foundation

/// Builds the argv for a headless `claude` run.
///
/// A real argument array rather than a shell string, so nothing needs quoting
/// here. `HeadlessProcess` quotes and wraps it in a login shell, which is what
/// puts `claude` on PATH.
enum HeadlessCommand {
    /// `isModelExplicitlyChosen` distinguishes a model the user picked from
    /// one that is only a snapshot of what the conversation already ran on.
    static func arguments(
        resumeSessionID: String?,
        permissionMode: PermissionMode?,
        settingsPath: String?,
        model: AgentModel? = nil,
        isModelExplicitlyChosen: Bool = true
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

        // Left off entirely when unset, so the CLI keeps its own default
        // rather than being pinned to a guess.
        //
        // A resume drops it too unless the user picked the model since. A bare
        // `--resume` restores the model the conversation already used, so
        // passing an unchosen snapshot back can only override a model changed
        // elsewhere — see "Model on resume" in docs/headless-protocol.md.
        let isResuming = !(resumeSessionID ?? "").isEmpty
        if let model, isModelExplicitlyChosen || !isResuming {
            arguments.append("--model")
            arguments.append(model.token)
        }

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
    ///
    /// `exec`s, so the login shell becomes `claude` rather than fathering it.
    /// Terminating the session depends on it: the pid Plume holds has to be
    /// the one it means to signal.
    static func loginShellCommand(arguments: [String]) -> String {
        LoginShellCommand.wrapExec(arguments.map(shellQuoted).joined(separator: " "))
    }
}
