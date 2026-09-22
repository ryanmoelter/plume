import Foundation

/// Why a headless chat never started, in the terms the chat view needs to
/// show it: a headline, the raw reason behind it, and what the user can do.
///
/// `claude -p` that dies before emitting any stream-json leaves nothing on
/// disk, so its last stderr line is the only account of what went wrong.
/// This classifies that line into the few causes worth wording specially and
/// passes everything else through verbatim.
nonisolated struct ChatStartFailure: Equatable {
    /// What the user can do about it, beyond reading the reason.
    enum Remedy: Equatable {
        /// Send the message again; nothing needs fixing first.
        case retry
        /// `claude` has to be installed, or put on the login shell's PATH,
        /// before a retry can work.
        case installCLI
        /// Claude Code has not been told to trust the directory, so the fix is
        /// a terminal tab, where the folder-trust prompt can be answered.
        case trustDirectory
    }

    /// The refusal `AgentLauncher` reports when it will not spawn into a
    /// directory Claude Code has no record of trusting.
    static func untrustedDirectory(path: String) -> ChatStartFailure {
        ChatStartFailure(
            title: "This directory isn't trusted",
            detail: "Claude Code needs to ask about \((path as NSString).lastPathComponent) before it can run there, and this chat can't show that prompt.",
            remedy: .trustDirectory
        )
    }

    let title: String
    /// The raw line behind the headline, shown verbatim. Nil when the title
    /// already says everything.
    let detail: String?
    let remedy: Remedy

    /// Nil when the session is healthy or stopped cleanly: only a nonzero
    /// exit with something to say is worth interrupting the empty state for.
    ///
    /// `exitStatus` is nil for a launch that threw before the process ran,
    /// which is still a failure — the thrown error is in `error`.
    static func classify(error: String?, exitStatus: Int32?) -> ChatStartFailure? {
        if let exitStatus, exitStatus == 0 { return nil }
        guard let error = error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty else {
            guard let exitStatus else { return nil }
            return ChatStartFailure(
                title: "Claude Code exited unexpectedly",
                detail: "Exit status \(exitStatus).",
                remedy: .retry
            )
        }
        if isCommandNotFound(error) {
            return ChatStartFailure(
                title: "Claude Code isn't on PATH",
                detail: error,
                remedy: .installCLI
            )
        }
        return ChatStartFailure(title: "Claude Code couldn't start", detail: error, remedy: .retry)
    }

    /// The shell's own wording, which differs per shell and per locale of
    /// phrasing: `zsh: command not found: claude`, `sh: claude: command not
    /// found`, `… : No such file or directory`. Matching the command name
    /// alongside the phrase keeps an unrelated missing binary from claiming
    /// the CLI is the thing that's absent.
    private static func isCommandNotFound(_ error: String) -> Bool {
        let lowered = error.lowercased()
        guard lowered.contains("claude") else { return false }
        return lowered.contains("command not found")
            || lowered.contains("no such file or directory")
            || lowered.contains("not found")
    }
}
