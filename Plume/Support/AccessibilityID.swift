import Foundation

/// Identifiers for driving the app through the accessibility tree —
/// `PlumeUITests` and any external driver query controls by these strings
/// rather than by their visible label, which can change or localize.
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
    static let keepAwakePanel = "keep-awake-panel"
    static let keepAwakeModePicker = "keep-awake-mode-picker"
    static let keepAwakeReasonRow = "keep-awake-reason-row"
    static let keepAwakeLidNote = "keep-awake-lid-note"
    static let keepAwakeLidToggle = "keep-awake-lid-toggle"
    static let keepAwakeLidApprovalButton = "keep-awake-lid-approval-button"

    // MARK: Tab strip

    static let tabChip = "tab-chip"
    static let tabChipClose = "tab-chip-close"
    static let newTabButton = "new-tab-button"

    // MARK: Composer

    static let composerField = "composer-field"
    static let composerSendButton = "composer-send-button"
    static let composerStopButton = "composer-stop-button"
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
