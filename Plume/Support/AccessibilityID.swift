import Foundation

/// Identifiers passed to `plumeID(_:)`, which sets the accessibility
/// identifier and registers the control with the debug control server.
/// `PlumeUITests` and other drivers query by these, not by the visible label.
enum AccessibilityID {
    // MARK: Sidebar

    static let taskRow = "task-row"
    static let groupHeader = "group-header"
    static let groupHeaderNewTaskButton = "group-header-new-task-button"
    static let groupHeaderDisclosureButton = "group-header-disclosure-button"
    static let newTaskButton = "new-task-button"
    static let newGroupButton = "new-group-button"
    static let sidebarArchiveButton = "sidebar-archive-button"
    static let taskArchiveButton = "task-archive-button"
    static let archivedTaskUnarchiveButton = "archived-task-unarchive-button"
    static let sidebarSettingsButton = "sidebar-settings-button"
    static let sidebarKeepAwakeButton = "sidebar-keep-awake-button"
    static let sidebarQuotaRow = "sidebar-quota-row"
    static let sidebarBuildLabel = "sidebar-build-label"
    static let keepAwakePanel = "keep-awake-panel"
    static let keepAwakeModePicker = "keep-awake-mode-picker"
    static let keepAwakeReasonRow = "keep-awake-reason-row"
    static let keepAwakeLidNote = "keep-awake-lid-note"
    static let keepAwakeLidToggle = "keep-awake-lid-toggle"
    static let keepAwakeLidApprovalButton = "keep-awake-lid-approval-button"
    static let keepAwakeLidInstallButton = "keep-awake-lid-install-button"
    static let keepAwakeLidUninstallButton = "keep-awake-lid-uninstall-button"
    static let keepAwakeThermalPicker = "keep-awake-thermal-picker"
    static let sidebarUpdateButton = "sidebar-update-button"
    static let updatePanel = "update-panel"
    static let updatePanelCopyBrewCommandButton = "update-panel-copy-brew-command-button"
    static let updatePanelFullReleaseNotesLink = "update-panel-full-release-notes-link"

    // MARK: Settings

    static let shortcutRecorder = "shortcut-recorder"
    static let shortcutResetButton = "shortcut-reset-button"
    static let shortcutResetAllButton = "shortcut-reset-all-button"
    static let fullDiskAccessOpenButton = "full-disk-access-open-button"
    static let fullDiskAccessDismissButton = "full-disk-access-dismiss-button"
    static let fullDiskAccessStatus = "full-disk-access-status"
    static let fullDiskAccessManageButton = "full-disk-access-manage-button"
    static let updatesAutoCheckToggle = "updates-auto-check-toggle"
    static let updatesCheckNowButton = "updates-check-now-button"
    static let updatesInstallSourcePicker = "updates-install-source-picker"

    // MARK: Tab strip

    static let tabChip = "tab-chip"
    static let tabChipClose = "tab-chip-close"
    static let newTabButton = "new-tab-button"

    // MARK: Composer

    static let composerField = "composer-field"
    static let composerSendButton = "composer-send-button"
    static let composerStopButton = "composer-stop-button"
    static let composerSteerButton = "composer-steer-button"
    static let composerModelControl = "composer-model-control"
    static let composerEffortControl = "composer-effort-control"
    static let composerPermissionModeControl = "composer-permission-mode-control"
    static let remoteControlToast = "remote-control-toast"

    // MARK: Statusline strip

    // The workspace and Remote Control segments keep their `composer-`
    // strings, which external drivers already query.
    static let composerWorkspacePicker = "composer-workspace-picker"
    static let composerRemoteControlControl = "composer-remote-control-control"
    static let statuslineFiveHourMeter = "statusline-five-hour-meter"
    static let statuslineSevenDayMeter = "statusline-seven-day-meter"
    static let statuslineContextMeter = "statusline-context-meter"
    static let statuslineCost = "statusline-cost"
    static let statuslineBranch = "statusline-branch"

    // MARK: Chat start failure

    static let chatStartFailureRetry = "chat-start-failure-retry"
    static let chatTrustOpenTerminal = "chat-trust-open-terminal"

    static let workspaceWorktreeMenu = "workspace-worktree-menu"

    // MARK: New worktree sheet

    static let worktreeBranchField = "worktree-branch-field"
    static let worktreeStripPrefixToggle = "worktree-strip-prefix-toggle"
    static let worktreeEditLocationButton = "worktree-edit-location-button"
    static let worktreeLocationField = "worktree-location-field"
    static let worktreeChooseLocationButton = "worktree-choose-location-button"
    static let worktreeCreateButton = "worktree-create-button"
    static let worktreeCancelButton = "worktree-cancel-button"

    // MARK: Plan overlay

    static let planApproveButton = "plan-approve-button"
    static let planRejectButton = "plan-reject-button"
    static let planFeedbackField = "plan-feedback-field"
    static let planMinimizeButton = "plan-minimize-button"
    static let planCloseButton = "plan-close-button"
    static let planExpandButton = "plan-expand-button"
    static let planLinkButton = "plan-link-button"

    // MARK: AskUserQuestion

    static let questionOption = "question-option"
    static let questionFreeTextField = "question-free-text-field"

    // MARK: Permission request

    static let permissionDenialReasonField = "permission-denial-reason-field"

    // MARK: Markdown

    static let mermaidExpandButton = "mermaid-expand-button"
    static let mermaidFullScreenClose = "mermaid-full-screen-close"

    // MARK: Subagents

    static let subagentRow = "subagent-row"
    static let completedSubagentsToggle = "completed-subagents-toggle"
    static let subagentMarkDone = "subagent-mark-done"
    static let subagentMarkInterrupted = "subagent-mark-interrupted"
    static let subagentClearOverride = "subagent-clear-override"
    static let subagentTranscriptClose = "subagent-transcript-close"

    // MARK: Minimap

    static let chatMinimap = "chat-minimap"
    static let chatMinimapEntry = "chat-minimap-entry"
}
