import Foundation

/// Reads the permission mode the user has already configured for the Claude
/// Code CLI itself, so Plume's "follow Claude Code" default can defer to it.
///
/// Pure over an injected file path, mirroring `GhosttyConfigLoader`, so
/// resolution is testable without touching the real `~/.claude`.
nonisolated enum ClaudeCodeSettingsResolver {
    /// `~/.claude/settings.json`, Claude Code's own settings file.
    static var defaultSettingsPath: String {
        "\(NSHomeDirectory())/.claude/settings.json"
    }

    /// `permissions.defaultMode` from the settings file, or nil when the file
    /// is absent, unreadable, malformed, or the key is missing — any of
    /// which means letting the CLI decide for itself.
    static func resolvedDefaultPermissionMode(
        settingsPath: String = defaultSettingsPath
    ) -> PermissionMode? {
        guard let data = FileManager.default.contents(atPath: settingsPath) else {
            return nil
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let permissions = json["permissions"] as? [String: Any],
            let defaultMode = permissions["defaultMode"] as? String
        else {
            return nil
        }
        return PermissionMode(rawValue: defaultMode)
    }
}
