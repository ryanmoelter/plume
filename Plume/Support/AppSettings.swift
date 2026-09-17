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
        static let chatFontSize = "chatFontSize"
        static let confirmQuitWhileWorking = "confirmQuitWhileWorking"
        static let confirmSystemInitiatedQuit = "confirmSystemInitiatedQuit"
        static let composerSendKeyRaw = "composerSendKeyRaw"
        static let defaultAgentTransportRaw = "defaultAgentTransportRaw"
        static let defaultPermissionModeRaw = "defaultPermissionModeRaw"
        static let defaultEffortRaw = "defaultEffortRaw"
        /// Stored under its original name, from when the setting covered
        /// only row heights, so an existing preference still reads.
        static let animateChatMotion = "animateRowHeight"
        static let animateCharacterReveal = "animateCharacterReveal"
        static let showsPullRequestStatus = "showsPullRequestStatus"
        static let ignoredPendingChecks = "ignoredPendingChecks"
        static let notifiesOnTurnEnd = "notifiesOnTurnEnd"
        static let keepAwakeModeRaw = "keepAwakeModeRaw"
        static let keepsAwakeOnBattery = "keepsAwakeOnBattery"
        static let keepsAwakeWithLidClosed = "keepsAwakeWithLidClosed"
        static let chatListEngineRaw = "chatListEngineRaw"
    }

    /// Effort a tab starts at when it has never chosen one. The CLI reports
    /// effort back nowhere and documents no default, so this is Plume's own
    /// choice: the middle of the five levels, and settable.
    nonisolated static let defaultEffort: AgentEffort = .medium

    /// 125% of the system `.body` size (13pt on macOS).
    nonisolated static let defaultChatFontSize: Double = 16
    nonisolated static let chatFontSizeRange: ClosedRange<Double> = 11...28

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.worktreeBasePath = defaults.string(forKey: Key.worktreeBasePath)
        self.providerID = defaults.string(forKey: Key.providerID) ?? ClaudeCodeProviderID

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

        self.composerSendKey = defaults.string(forKey: Key.composerSendKeyRaw)
            .flatMap(ComposerSendKey.init(rawValue:)) ?? .commandReturn

        self.defaultAgentTransport = defaults.string(forKey: Key.defaultAgentTransportRaw)
            .flatMap(AgentTransport.init(rawValue:)) ?? .headless

        self.defaultPermissionMode = defaults.string(forKey: Key.defaultPermissionModeRaw)
            .flatMap(PermissionModeDefault.init(rawValue:)) ?? .followClaudeCode

        self.defaultEffort = defaults.string(forKey: Key.defaultEffortRaw)
            .flatMap(AgentEffort.init(rawValue:)) ?? Self.defaultEffort

        // Unset must read as true, which `bool(forKey:)` cannot express.
        self.animateChatMotion = defaults.object(forKey: Key.animateChatMotion) == nil
            ? true
            : defaults.bool(forKey: Key.animateChatMotion)
        self.animateCharacterReveal = defaults.object(forKey: Key.animateCharacterReveal) == nil
            ? true
            : defaults.bool(forKey: Key.animateCharacterReveal)

        // Unset must read as true: the feature is opt-out, not opt-in.
        self.showsPullRequestStatus = defaults.object(forKey: Key.showsPullRequestStatus) == nil
            ? true
            : defaults.bool(forKey: Key.showsPullRequestStatus)
        self.ignoredPendingChecks = defaults.stringArray(forKey: Key.ignoredPendingChecks) ?? []

        // Unset reads as false, which is the wanted default.
        self.notifiesOnTurnEnd = defaults.bool(forKey: Key.notifiesOnTurnEnd)

        self.keepAwakeMode = defaults.string(forKey: Key.keepAwakeModeRaw)
            .flatMap(KeepAwakeMode.init(rawValue:)) ?? .auto

        // Unset reads as false: holding a Mac awake on battery drains it,
        // so it is the direction to ask for rather than inherit.
        self.keepsAwakeOnBattery = defaults.bool(forKey: Key.keepsAwakeOnBattery)

        // Unset reads as false: turning this on installs a privileged helper
        // and asks for admin approval, which has to be the user's move.
        self.keepsAwakeWithLidClosed = defaults.bool(forKey: Key.keepsAwakeWithLidClosed)

        self.chatListEngine = defaults.string(forKey: Key.chatListEngineRaw)
            .flatMap(ChatListEngine.init(rawValue:)) ?? .custom
    }

    /// The container behind the chat list. The custom list by default so it
    /// gets daily use before the lazy stack goes; the toggle is the way back.
    /// `ChatListEngine.environmentOverride` wins over both for a harness run.
    var chatListEngine: ChatListEngine {
        didSet {
            defaults.set(chatListEngine.rawValue, forKey: Key.chatListEngineRaw)
        }
    }

    var effectiveChatListEngine: ChatListEngine {
        ChatListEngine.environmentOverride ?? chatListEngine
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
    /// `.working` or waiting on the user shows a confirmation alert.
    var confirmQuitWhileWorking: Bool {
        didSet {
            defaults.set(confirmQuitWhileWorking, forKey: Key.confirmQuitWhileWorking)
        }
    }

    /// Whether a system-initiated quit (logout, restart, shutdown) while a
    /// tab is `.working` or waiting on the user also shows the alert. Off by
    /// default: a modal during an OS-initiated shutdown blocks that shutdown
    /// until someone dismisses it, and nobody may be there to do so.
    var confirmSystemInitiatedQuit: Bool {
        didSet {
            defaults.set(confirmSystemInitiatedQuit, forKey: Key.confirmSystemInitiatedQuit)
        }
    }

    /// Which key sends a chat message; the other key (with Shift) inserts a
    /// newline instead. See `ChatComposer`'s doc comment for the reasoning
    /// behind the default.
    var composerSendKey: ComposerSendKey {
        didSet {
            defaults.set(composerSendKey.rawValue, forKey: Key.composerSendKeyRaw)
        }
    }

    /// Transport a new agent tab starts with. The TUI stays reachable as an
    /// escape hatch by flipping this, or per-tab via the tab menu.
    var defaultAgentTransport: AgentTransport {
        didSet {
            defaults.set(defaultAgentTransport.rawValue, forKey: Key.defaultAgentTransportRaw)
        }
    }

    /// Permission mode a new agent tab starts in. Defaults to following
    /// whatever the user already configured for the Claude Code CLI itself.
    var defaultPermissionMode: PermissionModeDefault {
        didSet {
            defaults.set(defaultPermissionMode.rawValue, forKey: Key.defaultPermissionModeRaw)
        }
    }

    /// Effort a new agent tab starts at. There is no launch flag for effort,
    /// so this is what the composer shows and what seeds a new session.
    var defaultEffort: AgentEffort {
        didSet {
            defaults.set(defaultEffort.rawValue, forKey: Key.defaultEffortRaw)
        }
    }

    /// Whether the chat list moves rather than jumps: a row easing between
    /// heights as its content changes, a newly arrived one growing into
    /// place, and the room the composer takes easing as it grows.
    /// Separate from `animateCharacterReveal`: all three are size changes the
    /// list's bottom anchor reacts to, so they carry the higher risk of the
    /// two and have to be killable on their own.
    var animateChatMotion: Bool {
        didSet {
            defaults.set(animateChatMotion, forKey: Key.animateChatMotion)
        }
    }

    /// Whether streamed text arrives a character at a time rather than a
    /// delta at a time.
    var animateCharacterReveal: Bool {
        didSet {
            defaults.set(animateCharacterReveal, forKey: Key.animateCharacterReveal)
        }
    }

    /// Master toggle for GitHub PR status in the sidebar. The feature makes
    /// network calls, so it must be opt-outable; on by default.
    var showsPullRequestStatus: Bool {
        didSet {
            defaults.set(showsPullRequestStatus, forKey: Key.showsPullRequestStatus)
        }
    }

    /// Plume-level half of `IgnoredChecksResolver`'s union: check names whose
    /// perpetual PENDING is ignored, across every repo. Matched by exact
    /// string equality against the check's name/context.
    var ignoredPendingChecks: [String] {
        didSet {
            let trimmed = ignoredPendingChecks
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if trimmed != ignoredPendingChecks {
                ignoredPendingChecks = trimmed
                return
            }
            defaults.set(ignoredPendingChecks, forKey: Key.ignoredPendingChecks)
        }
    }

    /// How much say Plume has over system sleep. `auto` holds the Mac awake
    /// only while `KeepAwakeCoordinator` finds a reason.
    var keepAwakeMode: KeepAwakeMode {
        didSet {
            defaults.set(keepAwakeMode.rawValue, forKey: Key.keepAwakeModeRaw)
        }
    }

    /// Whether keep-awake also applies on battery power. Off by default: the
    /// OS may ignore a sleep assertion on battery anyway, and draining a
    /// laptop the user walked away from is the worse failure.
    var keepsAwakeOnBattery: Bool {
        didSet {
            defaults.set(keepsAwakeOnBattery, forKey: Key.keepsAwakeOnBattery)
        }
    }

    /// Whether a hold also keeps the Mac awake through a lid close, via the
    /// `PlumeSleepHelper` daemon. Rides on top of a hold, so on battery it
    /// also needs `keepsAwakeOnBattery`.
    var keepsAwakeWithLidClosed: Bool {
        didSet {
            defaults.set(keepsAwakeWithLidClosed, forKey: Key.keepsAwakeWithLidClosed)
        }
    }

    /// Whether a tab finishing its turn posts a notification. Off by default:
    /// a turn ends every time the agent stops talking, so notifying on each
    /// one is far chattier than the states that actually need an answer,
    /// which notify regardless of this setting.
    var notifiesOnTurnEnd: Bool {
        didSet {
            defaults.set(notifiesOnTurnEnd, forKey: Key.notifiesOnTurnEnd)
        }
    }

    /// The model a launch that passes no `--model` will run on, read from the
    /// CLI's own settings. Nil when nothing is configured there.
    var resolvedDefaultModel: AgentModel? {
        ClaudeCodeSettingsResolver.resolvedDefaultModel()
    }

    /// Resolves `defaultPermissionMode` to an actual `PermissionMode`,
    /// consulting `~/.claude/settings.json` when following Claude Code.
    var resolvedDefaultPermissionMode: PermissionMode? {
        switch defaultPermissionMode {
        case .followClaudeCode:
            return ClaudeCodeSettingsResolver.resolvedDefaultPermissionMode()
        default:
            return defaultPermissionMode.permissionMode
        }
    }
}

enum ComposerSendKey: String {
    case returnKey
    case commandReturn
}
