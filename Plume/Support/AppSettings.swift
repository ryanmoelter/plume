import Foundation

/// User-configurable preferences, persisted to `UserDefaults`.
///
/// This is the seam WP4.2 asks for: a worktree base path override (read by
/// `WorkspaceProvisioner`) and a provider choice (read by `AgentLauncher`).
/// Only Claude Code exists today, so the provider field is a stub that
/// already round-trips end to end.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let worktreeBasePath = "worktreeBasePath"
        static let providerID = "providerID"
        static let statuslineCaptureEnabled = "statuslineCaptureEnabled"
        static let statuslineBackedUpCommand = "statuslineBackedUpCommand"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.worktreeBasePath = defaults.string(forKey: Key.worktreeBasePath)
        self.providerID = defaults.string(forKey: Key.providerID) ?? ClaudeCodeProviderID
        self.statuslineCaptureEnabled = defaults.bool(forKey: Key.statuslineCaptureEnabled)
        self.statuslineBackedUpCommand = defaults.string(forKey: Key.statuslineBackedUpCommand)
    }

    /// Overrides where worktrees are created. Nil (the default) means
    /// `<repo>/.plume/worktrees`.
    var worktreeBasePath: String? {
        didSet {
            defaults.set(worktreeBasePath, forKey: Key.worktreeBasePath)
        }
    }

    /// The agent provider to launch. Only `claude-code` is implemented in v1;
    /// this persists and is read by `AgentLauncher`, ready for more providers.
    var providerID: String {
        didSet {
            defaults.set(providerID, forKey: Key.providerID)
        }
    }

    /// Whether Plume's statusline capture script is installed as
    /// `~/.claude/settings.json`'s `statusLine.command`. Ships off; only the
    /// Settings UI's Install/Restore buttons flip this and touch that file.
    var statuslineCaptureEnabled: Bool {
        didSet {
            defaults.set(statuslineCaptureEnabled, forKey: Key.statuslineCaptureEnabled)
        }
    }

    /// The `statusLine.command` `install()` overwrote, shown in Settings so
    /// Restore's effect is visible before pressing it. `StatuslineInstaller`
    /// keeps its own on-disk backup as the source of truth for `restore()`
    /// itself; this is a display mirror of it.
    var statuslineBackedUpCommand: String? {
        didSet {
            defaults.set(statuslineBackedUpCommand, forKey: Key.statuslineBackedUpCommand)
        }
    }
}
