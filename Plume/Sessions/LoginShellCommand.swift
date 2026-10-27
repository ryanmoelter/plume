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

    /// `plumeEnvironment` plus the socket the `plume` tool reaches this app
    /// through, when this app serves one, and this app's bundle ID, whose
    /// defaults domain holds the settings the tool reads. For a process
    /// serving many tabs, which has no one tab to name.
    static func sharedPlumeEnvironment() -> [String: String] {
        sharedPlumeEnvironment(socketPath: CLIServer.shared.socketPath, bundleID: Bundle.main.bundleIdentifier)
    }

    static func sharedPlumeEnvironment(socketPath: String?, bundleID: String?) -> [String: String] {
        var environment = plumeEnvironment
        environment[CLISocket.pathEnvironmentKey] = socketPath
        environment[UserDefaultsProjectSettingsSource.bundleIDEnvironmentKey] = bundleID
        return environment
    }

    /// Everything `plume` needs inside one tab: the shared environment, and
    /// which tab and task it runs in.
    static func plumeEnvironment(taskID: UUID?, tabID: UUID) -> [String: String] {
        plumeEnvironment(
            taskID: taskID, tabID: tabID, socketPath: CLIServer.shared.socketPath, bundleID: Bundle.main.bundleIdentifier
        )
    }

    static func plumeEnvironment(taskID: UUID?, tabID: UUID, socketPath: String?, bundleID: String?) -> [String: String] {
        var environment = sharedPlumeEnvironment(socketPath: socketPath, bundleID: bundleID)
        environment[CLISocket.tabIDEnvironmentKey] = tabID.uuidString
        environment[CLISocket.taskIDEnvironmentKey] = taskID?.uuidString
        return environment
    }

    /// Keys that name a Plume instance, tab or task. A Plume launched from
    /// another Plume's tab inherits that one's values, which would route a
    /// child's `plume` calls and hook events to the wrong app.
    nonisolated static let instanceKeys = [
        CLISocket.pathEnvironmentKey,
        CLISocket.tabIDEnvironmentKey,
        CLISocket.taskIDEnvironmentKey,
        UserDefaultsProjectSettingsSource.bundleIDEnvironmentKey,
        "PLUME_EVENTS_DIR",
    ]

    /// This process's environment plus `overrides`. It carries no inherited
    /// `instanceKeys`, since `dropInheritedInstanceKeys` cleared them at launch.
    nonisolated static func childEnvironment(overrides: [String: String]) -> [String: String] {
        ProcessInfo.processInfo.environment.merging(overrides) { $1 }
    }

    /// Clears `instanceKeys` from this process at launch, so no child
    /// inherits them, however its environment is built.
    static func dropInheritedInstanceKeys() {
        for key in instanceKeys { unsetenv(key) }
    }

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

    /// Renders argv as one login-shell command line, quoting each argument so
    /// spaces and JSON punctuation survive the trip through the shell.
    static func wrap(arguments: [String]) -> String {
        wrap(arguments.map(shellQuoted).joined(separator: " "))
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


    /// A bare login, interactive shell with no inner command — for plain
    /// terminal tabs, where the "command" is just an interactive prompt.
    static func loginShell(shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> String {
        let resolvedShell = shell?.isEmpty == false ? shell! : "/bin/zsh"
        return "\(resolvedShell) -li"
    }
}
