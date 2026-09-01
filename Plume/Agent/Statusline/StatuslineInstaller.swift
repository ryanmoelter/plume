import Foundation

/// Reads and rewrites `~/.claude/settings.json`'s `statusLine` object.
///
/// `statusLine` is a single object, so installing replaces it rather than
/// unioning the way hook lists do — unlike `HookSettingsWriter`, this can't
/// just add alongside the user's config. `install()`/`restore()` are the only
/// entry points that touch the real file, and both must be called only from
/// a user-initiated Settings action — never at launch.
enum StatuslineInstaller {
    struct StatusLineCommand: Equatable {
        let type: String
        let command: String
        let padding: Int?

        var json: [String: Any] {
            var dict: [String: Any] = ["type": type, "command": command]
            if let padding { dict["padding"] = padding }
            return dict
        }
    }

    enum InstallerError: Error, Equatable {
        case settingsUnreadable
        case settingsMalformed
        case noBackupRecorded
    }

    /// The command Plume installs as `statusLine.command` — reachable inside
    /// the generated capture script's own directory.
    static let pluginCommand = AppPaths.statuslineScriptFile.path

    /// Reads `settings.json` at `settingsURL` and returns its current
    /// `statusLine` object, or nil when the key is absent. Read-only.
    static func currentStatusLine(settingsURL: URL) -> StatusLineCommand? {
        guard let dict = readSettings(at: settingsURL),
              let statusLine = dict["statusLine"] as? [String: Any]
        else { return nil }
        return parse(statusLine)
    }

    /// True when `statusLine.command` already points at Plume's own script —
    /// installing again would chain the script to itself, an infinite loop.
    static func isAlreadyInstalled(settingsURL: URL) -> Bool {
        currentStatusLine(settingsURL: settingsURL)?.command == pluginCommand
    }

    /// The exact JSON `install()` would write, without writing it — what the
    /// Settings UI shows the user before they opt in.
    static func preview(settingsURL: URL) -> String {
        let object: [String: Any] = [
            "type": "command",
            "command": pluginCommand,
            "padding": 0,
        ]
        return prettyJSON(object)
    }

    /// Installs Plume's capture script as `statusLine.command`, chaining to
    /// whatever was previously configured (or nothing, if `statusLine` was
    /// absent). Backs the previous value up to `backupURL` and returns it so
    /// the caller can record it for `restore()`.
    ///
    /// A no-op (returns the current value, writes nothing) when already
    /// installed, so re-invoking never creates a self-chain.
    @discardableResult
    static func install(settingsURL: URL, backupURL: URL) throws -> StatusLineCommand? {
        guard let dict = readSettings(at: settingsURL) else {
            throw InstallerError.settingsUnreadable
        }

        let previous = (dict["statusLine"] as? [String: Any]).flatMap(parse)
        if previous?.command == pluginCommand {
            return previous
        }

        // Records "there was no statusLine key" too — restore() must be able
        // to remove the key again, not just fail to find a backup.
        try writeBackup(previous, to: backupURL)

        let chainCommand = previous?.command ?? ""
        try StatuslineCaptureWriter.write(chainCommand: chainCommand)

        var updated = dict
        updated["statusLine"] = [
            "type": "command",
            "command": pluginCommand,
            "padding": 0,
        ]
        try writeSettings(updated, to: settingsURL)

        return previous
    }

    /// Restores `statusLine` to whatever `backupURL` recorded, then removes
    /// the backup file. Throws if there's nothing to restore.
    static func restore(settingsURL: URL, backupURL: URL) throws {
        guard let backup = readBackup(from: backupURL) else {
            throw InstallerError.noBackupRecorded
        }
        guard var dict = readSettings(at: settingsURL) else {
            throw InstallerError.settingsUnreadable
        }

        if let backup {
            dict["statusLine"] = backup.json
        } else {
            dict.removeValue(forKey: "statusLine")
        }
        try writeSettings(dict, to: settingsURL)
        try? FileManager.default.removeItem(at: backupURL)
    }

    // MARK: - Parsing

    private static func parse(_ dict: [String: Any]) -> StatusLineCommand? {
        guard let type = dict["type"] as? String,
              let command = dict["command"] as? String
        else { return nil }
        return StatusLineCommand(type: type, command: command, padding: dict["padding"] as? Int)
    }

    private static func readSettings(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else {
            // Absent settings.json is a valid starting point: nothing to chain to.
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return nil }
        return dict
    }

    private static func writeSettings(_ dict: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func prettyJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Backup

    /// `nil` records "there was no `statusLine` key" as a genuine, distinct
    /// backup state from "there was one to restore" — `restore()` treats a
    /// missing backup *file* as an error, but a backup recording nil as a
    /// valid instruction to remove the key.
    private static func writeBackup(_ previous: StatusLineCommand?, to url: URL) throws {
        let object: [String: Any] = previous.map { ["statusLine": $0.json] } ?? ["statusLine": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func readBackup(from url: URL) -> StatusLineCommand?? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict.keys.contains("statusLine")
        else { return nil }

        if dict["statusLine"] is NSNull {
            return .some(nil)
        }
        guard let statusLine = dict["statusLine"] as? [String: Any] else { return nil }
        return .some(parse(statusLine))
    }
}
