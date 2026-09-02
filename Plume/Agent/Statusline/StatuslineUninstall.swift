import Foundation
import os

/// One-time removal of the statusline capture Plume used to install into
/// `~/.claude/settings.json`.
///
/// Earlier versions pointed `statusLine.command` at a generated script to read
/// quota and cost, which existed nowhere else. The headless stream pushes both
/// directly, so the script is gone — but `settings.json` belongs to the user
/// and Claude Code, and a `statusLine` naming a script Plume no longer writes
/// would break their statusline in every terminal, with nothing left in the
/// app to undo it.
///
/// Runs at launch, best-effort throughout: a failure logs and launch
/// continues. The `AppSettings` flag latches, so a statusline the user
/// configures afterwards is never touched.
@MainActor
enum StatuslineUninstall {
    nonisolated static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude")
            .appending(path: "settings.json")
    }

    nonisolated static var backupURL: URL {
        claudeSettingsURL.appendingPathExtension("plume-backup")
    }

    /// The path an install wrote as `statusLine.command`.
    nonisolated static var installedCommand: String {
        AppPaths.statuslineScriptFile.path
    }

    static func runIfNeeded(
        settings: AppSettings = .shared,
        settingsURL: URL = claudeSettingsURL,
        backupURL: URL = backupURL
    ) {
        guard !settings.statuslineCaptureRemoved else { return }
        settings.statuslineCaptureRemoved = true
        run(settingsURL: settingsURL, backupURL: backupURL)
    }

    /// Prefers the recorded backup, which knows whether the user had a
    /// `statusLine` of their own. Without one, the most Plume can safely do is
    /// drop its own command and leave anything else in place.
    static func run(settingsURL: URL, backupURL: URL) {
        let backup = readBackup(from: backupURL)
        guard backup != nil || installedStatusLine(in: settingsURL) != nil else { return }

        do {
            try restore(backup ?? nil, settingsURL: settingsURL)
            try? FileManager.default.removeItem(at: backupURL)
        } catch {
            Log.app.error("Could not remove the statusline capture: \(error, privacy: .public)")
        }

        try? FileManager.default.removeItem(at: AppPaths.statuslineScriptFile)
    }

    /// `statusLine` as Plume installed it, or nil when the key is absent or
    /// names someone else's command.
    static func installedStatusLine(in settingsURL: URL) -> [String: Any]? {
        guard let statusLine = readSettings(at: settingsURL)?["statusLine"] as? [String: Any],
              statusLine["command"] as? String == installedCommand
        else { return nil }
        return statusLine
    }

    /// A nil `previous` means the user had no `statusLine` before the install,
    /// so the key goes away rather than being restored to something.
    private static func restore(_ previous: [String: Any]?, settingsURL: URL) throws {
        guard var dict = readSettings(at: settingsURL) else { throw UninstallError.settingsUnreadable }

        if let previous {
            dict["statusLine"] = previous
        } else {
            dict.removeValue(forKey: "statusLine")
        }

        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private enum UninstallError: Error {
        case settingsUnreadable
    }

    private static func readSettings(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The double optional distinguishes "no backup was recorded" (outer nil)
    /// from "a backup recording that there was no `statusLine`" (inner nil),
    /// which is a genuine instruction to remove the key.
    private static func readBackup(from url: URL) -> [String: Any]?? {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              dict.keys.contains("statusLine")
        else { return nil }
        return .some(dict["statusLine"] as? [String: Any])
    }
}
