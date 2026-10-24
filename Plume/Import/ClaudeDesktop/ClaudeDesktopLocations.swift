import AppKit

/// The Claude desktop app's Code sessions, one JSON file per session under
/// `claude-code-sessions/<accountId>/<orgId>/`. Plume only reads them.
nonisolated enum ClaudeDesktopLocations {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude")
    }

    static var sessionsDirectory: URL {
        rootDirectory.appendingPathComponent("claude-code-sessions")
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: rootDirectory.path)
    }

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
