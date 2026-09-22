import Foundation

/// Builds the argv for a headless `claude` run.
///
/// A real argument array rather than a shell string, so nothing needs quoting
/// here. `AgentProcess` quotes and wraps it in a login shell, which is what
/// puts `claude` on PATH.
enum HeadlessCommand {
    static func launchPermissionMode(_ resolved: PermissionMode?) -> PermissionMode {
        resolved ?? .acceptEdits
    }

    /// Where a forking resume cuts the conversation, and the id the fork is
    /// given. `cutAfterMessageUUID` is the last entry to keep — to redo a
    /// message, pass that message's own parent.
    ///
    /// `--resume-session-at` is undocumented and absent from `claude --help`,
    /// so a CLI upgrade can withdraw it without warning. Forking is the
    /// secondary path for exactly that reason: `rewind_conversation` on the
    /// control plane does the same cut in place, and is documented.
    struct Fork: Equatable {
        let newSessionID: String
        let cutAfterMessageUUID: String
    }

    /// `isModelExplicitlyChosen` distinguishes a model the user picked from
    /// one that is only a snapshot of what the conversation already ran on.
    static func arguments(
        resumeSessionID: String?,
        permissionMode: PermissionMode?,
        settingsPath: String?,
        model: AgentModel? = nil,
        isModelExplicitlyChosen: Bool = true,
        fork: Fork? = nil
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
            "--permission-prompt-tool", "stdio",
            // Without this the CLI refuses `set_permission_mode` to
            // `bypassPermissions` mid-session. It starts no session in bypass.
            "--allow-dangerously-skip-permissions"
        ]

        // A `-p` session starts in Manual on every plan, so a mode is always
        // passed rather than left to the CLI's default. `permissionMode` is
        // expected to already be resolved (task override, or the user's
        // configured default); `.acceptEdits` here is only a last-resort
        // floor for when even that resolution comes back empty, not Plume's
        // preferred mode.
        arguments.append("--permission-mode")
        arguments.append(launchPermissionMode(permissionMode).token)

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

            // Only meaningful alongside `--resume`: the CLI writes the fork to
            // its own transcript under `newSessionID` and leaves the resumed
            // one untouched, so both conversations stay live.
            if let fork {
                arguments.append("--fork-session")
                arguments.append("--session-id")
                arguments.append(fork.newSessionID)
                arguments.append("--resume-session-at")
                arguments.append(fork.cutAfterMessageUUID)
            }
        }
        return arguments
    }
}
