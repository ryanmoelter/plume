import Foundation

/// Argv for the Codex app server.
///
/// `AgentProcess` quotes and wraps this in a login shell, which is what puts
/// `codex` on PATH for a GUI-launched app.
nonisolated enum CodexCommand {
    static func arguments() -> [String] {
        capturingShellEnvironment(["codex", "app-server"])
    }

    static func capturingShellEnvironment(_ arguments: [String]) -> [String] {
        ["/bin/sh", "-c", """
        if [ "${ZDOTDIR+x}" = x ]; then
          export PLUME_CODEX_ZDOTDIR_SET=1 PLUME_CODEX_ORIGINAL_ZDOTDIR="$ZDOTDIR"
        else
          export PLUME_CODEX_ZDOTDIR_SET=0
          unset PLUME_CODEX_ORIGINAL_ZDOTDIR
        fi
        exec "$@"
        """, "plume-codex"] + arguments
    }

    /// Notifications Plume never reads, declined at the handshake so the
    /// process stops writing them.
    ///
    /// `optOutNotificationMethods` matches **exact** method names, not
    /// prefixes, so a pattern here silently suppresses nothing. These are the
    /// ones a real session was seen to emit unprompted.
    static let ignoredNotifications = [
        "mcpServer/startupStatus/updated"
    ]
}
