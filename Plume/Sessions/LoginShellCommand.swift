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

    /// A bare login, interactive shell with no inner command — for plain
    /// terminal tabs, where the "command" is just an interactive prompt.
    static func loginShell(shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> String {
        let resolvedShell = shell?.isEmpty == false ? shell! : "/bin/zsh"
        return "\(resolvedShell) -li"
    }
}
