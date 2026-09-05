import Foundation

/// Argv for the Codex app server.
///
/// `AgentProcess` quotes and wraps this in a login shell, which is what puts
/// `codex` on PATH for a GUI-launched app.
nonisolated enum CodexCommand {
    static func arguments() -> [String] {
        ["codex", "app-server"]
    }

    /// Notifications Plume never reads, declined at the handshake so the
    /// process stops writing them.
    ///
    /// `optOutNotificationMethods` matches **exact** method names, not
    /// prefixes, so a pattern here silently suppresses nothing. These are the
    /// ones a real session was seen to emit unprompted.
    static let ignoredNotifications = [
        "mcpServer/startupStatus/updated",
        "remoteControl/status/changed"
    ]
}
