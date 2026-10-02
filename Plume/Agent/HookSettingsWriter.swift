import Foundation

/// Generates the `settings.json` passed to `claude --settings`.
///
/// Every hook is the same dependency-free one-liner appending its stdin to
/// `$PLUME_EVENTS_DIR/$PLUME_TASK_ID/$PLUME_TAB_ID.jsonl`. The payload already
/// carries `hook_event_name` and `session_id`, so capturing the session ID for
/// `--resume` comes free.
///
/// `--settings` merges with the user's own settings and hook lists union
/// rather than replace, so the user's hooks keep firing alongside these.
enum HookSettingsWriter {
    /// Events Plume derives status from.
    ///
    /// `Stop` and `UserPromptSubmit` reject a `matcher`, so the entry is
    /// emitted without one; for the rest, omitting it means "all" anyway.
    static let events = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "Stop",
        "SubagentStop",
        "Notification",
        "SessionEnd",
    ]

    /// A headless `claude` gets this file too, as the marker
    /// `ClaudeProcessScanner` finds Plume's processes by, but none of the
    /// variables. There the hook drains its stdin and succeeds, since appending
    /// to `//.jsonl` fails on every tool call.
    static let hookCommand = #"if [ -z "$PLUME_EVENTS_DIR" ]; then cat >/dev/null; else mkdir -p "$PLUME_EVENTS_DIR/$PLUME_TASK_ID" && cat >> "$PLUME_EVENTS_DIR/$PLUME_TASK_ID/$PLUME_TAB_ID.jsonl"; fi"#

    static func settingsJSON() -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": hookCommand,
                ]],
            ]]
        }
        return ["hooks": hooks]
    }

    /// Writes the settings file, returning its path.
    @discardableResult
    static func write() throws -> URL {
        try AppPaths.createDirectories()
        let data = try JSONSerialization.data(
            withJSONObject: settingsJSON(),
            options: [.prettyPrinted, .sortedKeys]
        )
        let url = AppPaths.hookSettingsFile
        try data.write(to: url, options: .atomic)
        return url
    }
}
