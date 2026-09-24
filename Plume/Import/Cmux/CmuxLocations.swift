import Foundation

/// The cmux layout and provider hook registries Plume reads.
///
/// `closed-item-history-*.json` is deliberately excluded: it retains raw
/// terminal scrollback, which can contain incidentally-typed secrets.
/// `workstream.jsonl` and `events.jsonl` are simply unnecessary for import.
nonisolated enum CmuxLocations {
    static var sessionFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux/session-com.cmuxterm.app.json")
    }

    static var hookSessionsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm/claude-hook-sessions.json")
    }

    static var codexHookSessionsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cmuxterm/codex-hook-sessions.json")
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: sessionFile.path)
    }
}
