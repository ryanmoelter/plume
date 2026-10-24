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
    static let taskRemoteControlToggle = "task-remote-control-toggle"
    static let taskDescription = "task-description"
    static let taskEditButton = "task-edit-button"
    static let groupEditButton = "group-edit-button"
    static let groupHeaderEditButton = "group-header-edit-button"
    static let sidebarNameField = "sidebar-name-field"
    static let sidebarDescriptionField = "sidebar-description-field"
    static let sidebarAppearancePopover = "sidebar-appearance-popover"
    static let sidebarTintSwatch = "sidebar-tint-swatch"
    static let sidebarIconSwatch = "sidebar-icon-swatch"
    static let sidebarSFSymbolsLink = "sidebar-sf-symbols-link"
    static let sidebarIconNameField = "sidebar-icon-name-field"
    static let sidebarIconClearButton = "sidebar-icon-clear-button"
    static let sidebarIconRevertButton = "sidebar-icon-revert-button"
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
    static let taskLinearIssueLine = "task-linear-issue-line"
    static let taskLinkLinearIssueMenuItem = "task-link-linear-issue-menu-item"
    static let linkLinearIssueField = "link-linear-issue-field"
    static let linkLinearIssueConfirmButton = "link-linear-issue-confirm-button"
    static let keepAwakeLidApprovalButton = "keep-awake-lid-approval-button"
    static let keepAwakeLidInstallButton = "keep-awake-lid-install-button"
    static let keepAwakeLidUninstallButton = "keep-awake-lid-uninstall-button"
    static let keepAwakeLidReinstallButton = "keep-awake-lid-reinstall-button"
    static let keepAwakeThermalPicker = "keep-awake-thermal-picker"
    static let sidebarUpdateButton = "sidebar-update-button"
    static let updatePanel = "update-panel"
    static let updatePanelCopyBrewCommandButton = "update-panel-copy-brew-command-button"
    static let updatePanelRunInTerminalButton = "update-panel-run-in-terminal-button"
    static let updatePanelFullReleaseNotesLink = "update-panel-full-release-notes-link"

    // MARK: Settings

    static let linearAPIKeyField = "linear-api-key-field"
    static let linearAddAccountButton = "linear-add-account-button"
    static let linearRemoveAccountButton = "linear-remove-account-button"
    static let linearAccountRow = "linear-account-row"
    static let linearAccountInfoButton = "linear-account-info-button"
    static let linearAccountRefreshButton = "linear-account-refresh-button"
    static let linearCreateKeyLink = "linear-create-key-link"
    static let linearShowIssuesToggle = "linear-show-issues-toggle"
    static let linearStateColorsPicker = "linear-state-colors-picker"
    static let linearShowAddFormButton = "linear-show-add-form-button"
    static let linearCancelAddButton = "linear-cancel-add-button"
    static let linearAccountDetailsToggle = "linear-account-details-toggle"
    static let linearStateColorsPreviewButton = "linear-state-colors-preview-button"

    static let settingsPane = "settings-pane"
    static let settingsThemeReloadButton = "settings-theme-reload-button"
    static let settingsAccentSwatch = "settings-accent-swatch"
    static let settingsSidebarShowsTaskColorBarToggle = "settings-sidebar-shows-task-color-bar-toggle"
    static let settingsSidebarColorsTaskNamesToggle = "settings-sidebar-colors-task-names-toggle"
    static let settingsSidebarBoldTaskNamesToggle = "settings-sidebar-bold-task-names-toggle"
    static let settingsSidebarColorsTaskIconsToggle = "settings-sidebar-colors-task-icons-toggle"
    static let settingsSidebarTwoToneIconsToggle = "settings-sidebar-two-tone-icons-toggle"
    static let settingsSidebarPreview = "settings-sidebar-preview"
    static let settingsSidebarSuggestsFilledIconsToggle = "settings-sidebar-suggests-filled-icons-toggle"
    static let importSourceItem = "import-source-item"
    static let sidebarImportMenu = "sidebar-import-menu"
    static let settingsImportCmuxButton = "settings-import-cmux-button"
    static let settingsImportOrcaButton = "settings-import-orca-button"
    static let settingsImportClaudeDesktopButton = "settings-import-claude-desktop-button"
    static let importRow = "import-row"
    static let importRunningWarning = "import-running-warning"
    static let importSelectAllButton = "import-select-all-button"
    static let importSelectNoneButton = "import-select-none-button"
    static let importCancelButton = "import-cancel-button"
    static let importConfirmButton = "import-confirm-button"
    static let settingsSeedFixturesButton = "settings-seed-fixtures-button"
    static let settingsAboutNotabilityLink = "settings-about-notability-link"
    static let settingsAboutHeypennyLink = "settings-about-heypenny-link"
    static let composerSendKeyPicker = "composer-send-key-picker"
    static let escapeInterruptsTurnToggle = "escape-interrupts-turn-toggle"
    static let queuedMessageDeliveryPicker = "queued-message-delivery-picker"
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
    static let debugUpdatesInstallSourcePicker = "debug-updates-install-source-picker"
    static let debugUpdatesFeedURLField = "debug-updates-feed-url-field"
    static let debugUpdatesCheckBackgroundButton = "debug-updates-check-background-button"
    static let debugUpdatesResetStateButton = "debug-updates-reset-state-button"

    // MARK: Tab strip

    static let tabChip = "tab-chip"
    static let tabChipClose = "tab-chip-close"
    /// In both the task row's and the tab chip's context menu.
    static let markUnreadButton = "mark-unread-button"
    /// Takes `markUnreadButton`'s place while any of its tabs is unread.
    static let markReadButton = "mark-read-button"
    static let newTabButton = "new-tab-button"
    /// One per on-screen tab; `value` is "focused" on the focused one.
    static let tabPane = "tab-pane"
    static let splitDivider = "split-divider"

    // MARK: Composer

    static let composerField = "composer-field"
    static let composerSendButton = "composer-send-button"
    static let composerStopButton = "composer-stop-button"
    static let composerSteerButton = "composer-steer-button"
    static let composerModelControl = "composer-model-control"
    static let composerEffortControl = "composer-effort-control"
    static let composerPermissionModeControl = "composer-permission-mode-control"
    static let composerCollaborationModeControl = "composer-collaboration-mode-control"
    static let remoteControlToast = "remote-control-toast"

    // MARK: Statusline strip

    // The workspace segment keeps its `composer-` string, which external
    // drivers already query.
    static let composerWorkspacePicker = "composer-workspace-picker"
    static let statuslineFiveHourMeter = "statusline-five-hour-meter"
    static let statuslineSevenDayMeter = "statusline-seven-day-meter"
    static let statuslineContextMeter = "statusline-context-meter"
    static let statuslineUsageButton = "statusline-usage-button"
    static let statuslineUsagePopover = "statusline-usage-popover"
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
    static let planTitleRow = "plan-title-row"
    static let planBackgroundDismiss = "plan-background-dismiss"
    static let planReviewButton = "plan-review-button"

    // MARK: AskUserQuestion

    static let questionOption = "question-option"
    static let questionFreeTextField = "question-free-text-field"

    // MARK: Permission request

    static let permissionDenialReasonField = "permission-denial-reason-field"

    // MARK: Markdown

    static let mermaidExpandButton = "mermaid-expand-button"
    static let mermaidFullScreenClose = "mermaid-full-screen-close"

    // MARK: Tool calls

    static let toolCallArtifactLink = "tool-call-artifact-link"

    // MARK: Subagents

    static let subagentRow = "subagent-row"
    static let subagentMarkDone = "subagent-mark-done"
    static let subagentMarkInterrupted = "subagent-mark-interrupted"
    static let subagentClearOverride = "subagent-clear-override"
    static let subagentTranscriptClose = "subagent-transcript-close"

    // MARK: Info pane

    static let infoPane = "info-pane"
    static let infoPaneCollapseButton = "info-pane-collapse-button"
    static let infoPanePill = "info-pane-pill"
    static let infoPaneFloatingDismiss = "info-pane-floating-dismiss"
    static let infoPaneSubagentsToggle = "info-pane-subagents-toggle"
    static let infoPaneCompletedToggle = "info-pane-completed-toggle"
    static let infoPaneBackgroundTasksToggle = "info-pane-background-tasks-toggle"
    static let infoPaneBackgroundTask = "info-pane-background-task"
    static let infoPanePlanRow = "info-pane-plan-row"
    static let infoPaneSideChatRow = "info-pane-side-chat-row"
    static let infoPaneRemoteControlMenu = "info-pane-remote-control-menu"
    static let infoPanePullRequestRow = "info-pane-pull-request-row"
    static let infoPaneLinearToggle = "info-pane-linear-toggle"
    static let infoPaneLinearCapToggle = "info-pane-linear-cap-toggle"
    static let infoPaneLinearMentionedToggle = "info-pane-linear-mentioned-toggle"
    static let infoPaneLinearIssueRow = "info-pane-linear-issue-row"
    static let infoPaneLinearCopyButton = "info-pane-linear-copy-button"
    static let infoPaneLinearMoveToMentionedButton = "info-pane-linear-move-to-mentioned-button"
    static let infoPaneLinearOpenButton = "info-pane-linear-open-button"
    static let infoPaneLinearLinkToConversationButton = "info-pane-linear-link-to-conversation-button"
    static let infoPaneLinearUnlinkButton = "info-pane-linear-unlink-button"
    static let infoPaneLinearRowMenu = "info-pane-linear-row-menu"
    static let infoPaneLinearAddButton = "info-pane-linear-add-button"
    static let infoPaneLinearLinkField = "info-pane-linear-link-field"
    static let infoPaneLinearLinkButton = "info-pane-linear-link-button"
    static let infoPaneArtifactsToggle = "info-pane-artifacts-toggle"
    static let infoPaneArtifactRow = "info-pane-artifact-row"

    // MARK: Side questions (/btw)

    static let sideQuestionsClose = "side-questions-close"
    static let sideQuestionChip = "side-question-chip"
    static let sideQuestionChipDismiss = "side-question-chip-dismiss"
    static let messageRollbackButton = "message-rollback-button"
    static let messageForkButton = "message-fork-button"
    static let rewindFailureToast = "rewind-failure-toast"
    static let messageForkMarker = "message-fork-marker"
    static let chatForkFailureCloseTab = "chat-fork-failure-close-tab"
    /// The title of a collapsible agent message, labelled with the message's
    /// key; clicking it collapses or expands the message.
    static let agentMessageToggle = "agent-message-toggle"
    /// The disclosure under a slash command, labelled with its piece id.
    static let slashCommandPrompt = "slash-command-prompt"
    static let agentMessageShowMore = "agent-message-show-more"
    static let agentMessageHide = "agent-message-hide"

    // MARK: Minimap

    static let chatMinimap = "chat-minimap"
    static let chatMinimapEntry = "chat-minimap-entry"

    // MARK: Queued messages

    static let queuedMessageSendNowButton = "queued-message-send-now-button"
    static let queuedMessageEditButton = "queued-message-edit-button"
    static let queuedMessageRemoveButton = "queued-message-remove-button"
    static let deliveringMessage = "delivering-message"
}
