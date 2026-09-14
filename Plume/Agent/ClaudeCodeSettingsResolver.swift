import Foundation

/// Reads what the user has already configured for the Claude Code CLI itself,
/// so Plume can show the values a launch will actually use rather than a
/// blank control.
///
/// Pure over injected file paths, mirroring `GhosttyConfigLoader`, so
/// resolution is testable without touching the real `~/.claude`.
///
/// The composer resolves these on every render, so each file's parse is kept
/// against its modification date and size: a call costs one `stat` unless the
/// file has changed, and an edit to `~/.claude/settings.json` still shows up
/// without a watcher.
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
        let configured = settings(inFileAt: localSettingsPath).model
            ?? settings(inFileAt: settingsPath).model
        return configured.flatMap(AgentModel.recognizing)
    }

    /// `permissions.defaultMode` from the settings file, or nil when the file
    /// is absent, unreadable, malformed, or the key is missing — any of
    /// which means letting the CLI decide for itself.
    static func resolvedDefaultPermissionMode(
        settingsPath: String = defaultSettingsPath
    ) -> PermissionMode? {
        settings(inFileAt: settingsPath).permissionsDefaultMode.flatMap(PermissionMode.init(rawValue:))
    }

    /// The keys Plume reads from one settings file.
    private struct Settings: Sendable {
        var model: String?
        var permissionsDefaultMode: String?

        static let empty = Settings()
    }

    private struct CacheEntry: Sendable {
        var modificationDate: Date?
        var size: Int
        var settings: Settings
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CacheEntry] = [:]

    private static func settings(inFileAt path: String) -> Settings {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .empty
        }
        let modificationDate = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let entry = cache[path], entry.modificationDate == modificationDate, entry.size == size {
            return entry.settings
        }
        let settings = parse(contentsOf: path)
        cache[path] = CacheEntry(modificationDate: modificationDate, size: size, settings: settings)
        return settings
    }

    private static func parse(contentsOf path: String) -> Settings {
        guard
            let data = FileManager.default.contents(atPath: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .empty
        }
        let permissions = object["permissions"] as? [String: Any]
        return Settings(
            model: object["model"] as? String,
            permissionsDefaultMode: permissions?["defaultMode"] as? String
        )
    }
}
