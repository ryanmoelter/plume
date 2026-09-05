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
    /// process stops writing them. Prefixes, matched against the method name.
    static let ignoredNotificationPrefixes = [
        "thread/realtime/",
        "fuzzyFileSearch/",
        "process/",
        "plugin/",
        "remoteControl/",
        "app/",
        "fs/"
    ]
}
