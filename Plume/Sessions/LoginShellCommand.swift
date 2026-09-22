import Foundation

/// Wraps a command so Ghostty runs it inside a login, interactive shell.
///
/// Ghostty's exec backend only applies login-shell semantics (`.zshenv`,
/// `.zprofile`, `.zshrc` sourced, full `PATH`) when it resolves the shell
/// itself. Setting `TerminalSurfaceOptions.command` bypasses that resolution
/// and execs the given string directly against a bare environment, so a
/// binary that reaches `PATH` only through the user's shell profile (like
/// `claude` at `~/.local/bin`) is "not found". Wrapping the command in
/// `$SHELL -lic '<command>'` restores login-shell semantics for both plain
/// terminals and agent tabs.
enum LoginShellCommand {
    /// Set on every tab's shell — terminal and agent, both transports — so a
    /// script or prompt can tell it's running inside Plume. Callers merge
    /// this into their own env dict; `wrap`/`loginShell` only build the
    /// command string and have no environment to carry it in.
    static let plumeEnvironment: [String: String] = ["PLUME": "1"]

    /// Builds `<shell> -lic '<command>'`, quoting `command` as a single
    /// argument so its own quoting is unaffected.
    ///
    /// `shell` defaults to `$SHELL`, falling back to `/bin/zsh` (this user's
    /// actual login shell, and a safe default in general) when unset.
    static func wrap(
        _ command: String,
        shell: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> String {
        let resolvedShell = shell?.isEmpty == false ? shell! : "/bin/zsh"
        return "\(resolvedShell) -lic \(shellQuoted(command))"
    }

    /// Builds `<shell> -lc '<command>'` — a login shell that is *not*
    /// interactive, for a command whose output is captured rather than shown
    /// in a terminal.
    ///
    /// An interactive shell sources `.zshrc`, which prints to stderr on any
    /// warning it hits (an unbound key, a missing terminfo entry). A terminal
    /// shows that once at startup and it scrolls away; captured output would
    /// carry it into every result instead. Dropping `i` keeps the login PATH
    /// that is the point of wrapping at all.
    static func wrapNonInteractive(
        _ command: String,
        shell: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> String {
        let resolvedShell = shell?.isEmpty == false ? shell! : "/bin/zsh"
        return "\(resolvedShell) -lc \(shellQuoted(command))"
    }

    /// Builds `<shell> -lic 'exec <command>'` — the login shell replaces
    /// itself with the command, so the spawned pid *is* the command's.
    ///
    /// A caller that means to signal the command later needs this. Without
    /// `exec` the shell stays in the middle, and a signal sent to the pid the
    /// caller holds reaches the shell while the real process keeps running,
    /// reparented to `init`.
    static func wrapExec(
        _ command: String,
        shell: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> String {
        wrap("exec " + command, shell: shell)
    }

    /// A bare login, interactive shell with no inner command — for plain
    /// terminal tabs, where the "command" is just an interactive prompt.
    static func loginShell(shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> String {
        let resolvedShell = shell?.isEmpty == false ? shell! : "/bin/zsh"
        return "\(resolvedShell) -li"
    }
}
