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
        static let codeFontSizeMultiplier = "codeFontSizeMultiplier"
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
        static let keepAwakeBatteryCutoffPercent = "keepAwakeBatteryCutoffPercent"
        static let keepsAwakeWithLidClosed = "keepsAwakeWithLidClosed"
        static let keepsAwakeForRemoteControl = "keepsAwakeForRemoteControl"
        static let showsKeepAwakeDebugReadout = "showsKeepAwakeDebugReadout"
        static let lidClosedThermalCutoffRaw = "lidClosedThermalCutoffRaw"
        static let showsBypassPermissions = "showsBypassPermissions"
        static let shortcutBindings = "shortcutBindings"
        static let hasPromptedForFullDiskAccess = "hasPromptedForFullDiskAccess"
        static let sidebarBackgroundStyleRaw = "sidebarBackgroundStyleRaw"
    }

    /// Effort a tab starts at when it has never chosen one. The CLI reports
    /// effort back nowhere and documents no default, so this is Plume's own
    /// choice: the middle of the five levels, and settable.
    nonisolated static let defaultEffort: AgentEffort = .medium

    /// 125% of the system `.body` size (13pt on macOS).
    nonisolated static let defaultChatFontSize: Double = 16
    nonisolated static let chatFontSizeRange: ClosedRange<Double> = 11...28

    /// Applied on top of `chatFontSize` for code spans and blocks, to match
    /// x-heights between the code face and the prose face at the same
    /// nominal size. 1.0 means no adjustment.
    nonisolated static let defaultCodeFontSizeMultiplier: Double = 1.0
    nonisolated static let codeFontSizeMultiplierRange: ClosedRange<Double> = 0.7...1.3

    /// Battery percentage below which keep-awake stops holding on battery.
    nonisolated static let defaultKeepAwakeBatteryCutoffPercent = 20

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

        // `double(forKey:)` returns 0 for an unset key, which is outside the
        // clamped range, so an unset key correctly falls back to the default.
        let storedCodeFontSizeMultiplier = defaults.double(forKey: Key.codeFontSizeMultiplier)
        self.codeFontSizeMultiplier = Self.codeFontSizeMultiplierRange.contains(storedCodeFontSizeMultiplier)
            ? storedCodeFontSizeMultiplier
            : Self.defaultCodeFontSizeMultiplier

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

        // `integer(forKey:)` returns 0 for an unset key, which collides with
        // 0 meaning "no cutoff" — an unset key must read as the default.
        self.keepAwakeBatteryCutoffPercent = defaults.object(forKey: Key.keepAwakeBatteryCutoffPercent) == nil
            ? Self.defaultKeepAwakeBatteryCutoffPercent
            : defaults.integer(forKey: Key.keepAwakeBatteryCutoffPercent)

        // Unset reads as false: turning this on installs a privileged helper
        // and asks for admin approval, which has to be the user's move.
        self.keepsAwakeWithLidClosed = defaults.bool(forKey: Key.keepsAwakeWithLidClosed)

        // Unset reads as on: a remotely driven session that sleeps mid-turn
        // strands whoever is driving it, with no way to wake it from away.
        self.keepsAwakeForRemoteControl = defaults.object(forKey: Key.keepsAwakeForRemoteControl) == nil
            ? true
            : defaults.bool(forKey: Key.keepsAwakeForRemoteControl)
        self.showsKeepAwakeDebugReadout = defaults.bool(forKey: Key.showsKeepAwakeDebugReadout)

        self.lidClosedThermalCutoff = defaults.string(forKey: Key.lidClosedThermalCutoffRaw)
            .flatMap(ThermalCutoffLevel.init(rawValue:)) ?? .serious

        // Unset reads as false: bypassing every permission check is worth
        // opting into, not stumbling onto.
        self.showsBypassPermissions = defaults.bool(forKey: Key.showsBypassPermissions)

        // A binding blob that no longer decodes falls back to the defaults
        // rather than failing the launch.
        self.shortcutBindings = defaults.data(forKey: Key.shortcutBindings)
            .flatMap { try? JSONDecoder().decode(ShortcutBindings.self, from: $0) }
            ?? ShortcutBindings()

        self.hasPromptedForFullDiskAccess = defaults.bool(forKey: Key.hasPromptedForFullDiskAccess)

        self.sidebarBackgroundStyle = defaults.string(forKey: Key.sidebarBackgroundStyleRaw)
            .flatMap(SidebarBackgroundStyle.init(rawValue:)) ?? .tintedGlass
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

    /// Multiplier on `chatFontSize` for code spans and blocks. Clamped to
    /// `codeFontSizeMultiplierRange`.
    var codeFontSizeMultiplier: Double {
        didSet {
            let clamped = min(
                max(codeFontSizeMultiplier, Self.codeFontSizeMultiplierRange.lowerBound),
                Self.codeFontSizeMultiplierRange.upperBound
            )
            if clamped != codeFontSizeMultiplier {
                codeFontSizeMultiplier = clamped
                return
            }
            defaults.set(codeFontSizeMultiplier, forKey: Key.codeFontSizeMultiplier)
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

    /// Battery percentage at or below which keep-awake stops holding, even
    /// when `keepsAwakeOnBattery` is on. 0 means no cutoff.
    var keepAwakeBatteryCutoffPercent: Int {
        didSet {
            let clamped = min(max(keepAwakeBatteryCutoffPercent, 0), 100)
            if clamped != keepAwakeBatteryCutoffPercent {
                keepAwakeBatteryCutoffPercent = clamped
                return
            }
            defaults.set(keepAwakeBatteryCutoffPercent, forKey: Key.keepAwakeBatteryCutoffPercent)
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

    /// Whether Remote Control on its own holds the Mac awake. Off, a tab is
    /// a reason only for work it is doing itself — being driven remotely
    /// stops counting, and stops promoting a waiting tab to a reason.
    var keepsAwakeForRemoteControl: Bool {
        didSet {
            defaults.set(keepsAwakeForRemoteControl, forKey: Key.keepsAwakeForRemoteControl)
        }
    }

    /// Debug builds only: the live power readout at the bottom of the Keep
    /// Awake popover, which polls while shown.
    var showsKeepAwakeDebugReadout: Bool {
        didSet {
            defaults.set(showsKeepAwakeDebugReadout, forKey: Key.showsKeepAwakeDebugReadout)
        }
    }

    /// The thermal level at or above which the lid-closed override releases,
    /// leaving the plain sleep assertion in place.
    var lidClosedThermalCutoff: ThermalCutoffLevel {
        didSet {
            defaults.set(lidClosedThermalCutoff.rawValue, forKey: Key.lidClosedThermalCutoffRaw)
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

    /// The user's chord for each rebindable menu command. Read by
    /// `PlumeShortcuts`, so a change here moves both the menu item and what
    /// `TerminalShortcutMonitor` claims back from a focused terminal.
    var shortcutBindings: ShortcutBindings {
        didSet {
            defaults.set(try? JSONEncoder().encode(shortcutBindings), forKey: Key.shortcutBindings)
            shortcutBindingsContinuation?.yield(shortcutBindings)
        }
    }

    private var shortcutBindingsContinuation: AsyncStream<ShortcutBindings>.Continuation?

    /// The bindings now, then every later set. `AppDelegate` writes each onto
    /// the menu; observation alone cannot, because the menu is built from a
    /// `Commands` body that SwiftUI never re-evaluates.
    ///
    /// One consumer only — a second call replaces the first's continuation.
    var shortcutBindingsStream: AsyncStream<ShortcutBindings> {
        AsyncStream { continuation in
            continuation.yield(shortcutBindings)
            shortcutBindingsContinuation = continuation
        }
    }

    /// Whether the Full Disk Access explanation has been shown. Set once the
    /// sheet is dismissed, however it is dismissed — the point is to explain
    /// the permission before an agent trips it, not to nag until it is
    /// granted.
    var hasPromptedForFullDiskAccess: Bool {
        didSet {
            defaults.set(hasPromptedForFullDiskAccess, forKey: Key.hasPromptedForFullDiskAccess)
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

    /// Whether the permission-mode pickers offer `bypassPermissions`. Off by
    /// default; a mode or default already stored as bypass still decodes and
    /// displays correctly regardless of this setting.
    var showsBypassPermissions: Bool {
        didSet {
            defaults.set(showsBypassPermissions, forKey: Key.showsBypassPermissions)
        }
    }

    /// How the sidebar's background is drawn. Defaults to `tintedGlass`, the
    /// closest match to the composer's own glass.
    var sidebarBackgroundStyle: SidebarBackgroundStyle {
        didSet {
            defaults.set(sidebarBackgroundStyle.rawValue, forKey: Key.sidebarBackgroundStyleRaw)
        }
    }
}

enum ComposerSendKey: String {
    case returnKey
    case commandReturn
}
