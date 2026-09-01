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
        static let chatFontSize = "chatFontSize"
        static let confirmQuitWhileWorking = "confirmQuitWhileWorking"
        static let confirmSystemInitiatedQuit = "confirmSystemInitiatedQuit"
    }

    /// 125% of the system `.body` size (13pt on macOS).
    nonisolated static let defaultChatFontSize: Double = 16
    nonisolated static let chatFontSizeRange: ClosedRange<Double> = 11...28

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.worktreeBasePath = defaults.string(forKey: Key.worktreeBasePath)
        self.providerID = defaults.string(forKey: Key.providerID) ?? ClaudeCodeProviderID
        self.statuslineCaptureEnabled = defaults.bool(forKey: Key.statuslineCaptureEnabled)
        self.statuslineBackedUpCommand = defaults.string(forKey: Key.statuslineBackedUpCommand)

        // `double(forKey:)` returns 0 for an unset key, so 0 (and anything
        // outside the clamped range) falls back to the default.
        let storedFontSize = defaults.double(forKey: Key.chatFontSize)
        self.chatFontSize = Self.chatFontSizeRange.contains(storedFontSize)
            ? storedFontSize
            : Self.defaultChatFontSize

        // `bool(forKey:)` returns false for an unset key, which would silently
        // flip the default to off — an unset key must read as true.
        self.confirmQuitWhileWorking = defaults.object(forKey: Key.confirmQuitWhileWorking) == nil
            ? true
            : defaults.bool(forKey: Key.confirmQuitWhileWorking)

        // Unset reads as false: an unattended OS-initiated restart or
        // shutdown should never stall on a modal nobody is there to dismiss.
        self.confirmSystemInitiatedQuit = defaults.bool(forKey: Key.confirmSystemInitiatedQuit)
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

    /// Point size for chat prose (`MarkdownView` and its sibling chat rows).
    /// Clamped to `chatFontSizeRange`.
    var chatFontSize: Double {
        didSet {
            let clamped = min(max(chatFontSize, Self.chatFontSizeRange.lowerBound), Self.chatFontSizeRange.upperBound)
            if clamped != chatFontSize {
                chatFontSize = clamped
                return
            }
            defaults.set(chatFontSize, forKey: Key.chatFontSize)
        }
    }

    /// Whether a user-initiated quit (⌘Q, Quit menu item) while a tab is
    /// `.working` or `.needsInput` shows a confirmation alert.
    var confirmQuitWhileWorking: Bool {
        didSet {
            defaults.set(confirmQuitWhileWorking, forKey: Key.confirmQuitWhileWorking)
        }
    }

    /// Whether a system-initiated quit (logout, restart, shutdown) while a
    /// tab is `.working` or `.needsInput` also shows the alert. Off by
    /// default: a modal during an OS-initiated shutdown blocks that shutdown
    /// until someone dismisses it, and nobody may be there to do so.
    var confirmSystemInitiatedQuit: Bool {
        didSet {
            defaults.set(confirmSystemInitiatedQuit, forKey: Key.confirmSystemInitiatedQuit)
        }
    }
}
