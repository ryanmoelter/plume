import Foundation

/// Reads what the user has already configured for the Claude Code CLI itself,
/// so Plume can show the values a launch will actually use rather than a
/// blank control.
///
/// Pure over injected file paths, mirroring `GhosttyConfigLoader`, so
/// resolution is testable without touching the real `~/.claude`.
nonisolated enum ClaudeCodeSettingsResolver {
    /// `~/.claude/settings.json`, Claude Code's own settings file.
    static var defaultSettingsPath: String {
        "\(NSHomeDirectory())/.claude/settings.json"
    }

    /// `~/.claude/settings.local.json`, which overrides the shared file.
    static var localSettingsPath: String {
        "\(NSHomeDirectory())/.claude/settings.local.json"
    }

    /// The model a launch without `--model` lands on: `model` from the local
    /// settings file, else the shared one. Nil when neither configures one, or
    /// when the configured value names a model this UI has no case for.
    static func resolvedDefaultModel(
        settingsPath: String = defaultSettingsPath,
        localSettingsPath: String = localSettingsPath
    ) -> AgentModel? {
        let configured = string(forKey: "model", inFileAt: localSettingsPath)
            ?? string(forKey: "model", inFileAt: settingsPath)
        return configured.flatMap(AgentModel.recognizing)
    }

    /// `permissions.defaultMode` from the settings file, or nil when the file
    /// is absent, unreadable, malformed, or the key is missing — any of
    /// which means letting the CLI decide for itself.
    static func resolvedDefaultPermissionMode(
        settingsPath: String = defaultSettingsPath
    ) -> PermissionMode? {
        guard
            let permissions = object(inFileAt: settingsPath)?["permissions"] as? [String: Any],
            let defaultMode = permissions["defaultMode"] as? String
        else {
            return nil
        }
        return PermissionMode(rawValue: defaultMode)
    }

    private static func string(forKey key: String, inFileAt path: String) -> String? {
        object(inFileAt: path)?[key] as? String
    }

    private static func object(inFileAt path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
