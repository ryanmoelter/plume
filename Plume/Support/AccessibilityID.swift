import Foundation

/// Identifiers for driving the app through the accessibility tree —
/// `PlumeUITests` and any external driver query controls by these strings
/// rather than by their visible label, which can change or localize.
enum AccessibilityID {
    // MARK: Sidebar

    static let taskRow = "task-row"
    static let groupHeader = "group-header"
    static let newTaskButton = "new-task-button"
    static let newGroupButton = "new-group-button"

    // MARK: Tab strip

    static let tabChip = "tab-chip"
    static let tabChipClose = "tab-chip-close"
    static let newTabButton = "new-tab-button"

    // MARK: Composer

    static let composerField = "composer-field"
    static let composerSendButton = "composer-send-button"
    static let composerStopButton = "composer-stop-button"
    static let composerWorkspacePicker = "composer-workspace-picker"
    static let composerModelControl = "composer-model-control"
    static let composerEffortControl = "composer-effort-control"
    static let composerPermissionModeControl = "composer-permission-mode-control"

    // MARK: Statusline strip

    static let statuslineFiveHourMeter = "statusline-five-hour-meter"
    static let statuslineSevenDayMeter = "statusline-seven-day-meter"
    static let statuslineCost = "statusline-cost"
    static let statuslineBranch = "statusline-branch"

    // MARK: Plan overlay

    static let planApproveButton = "plan-approve-button"
    static let planRejectButton = "plan-reject-button"
    static let planFeedbackField = "plan-feedback-field"
    static let planMinimizeButton = "plan-minimize-button"
    static let planCloseButton = "plan-close-button"
    static let planExpandButton = "plan-expand-button"

    // MARK: AskUserQuestion

    static let questionOption = "question-option"
    static let questionFreeTextField = "question-free-text-field"

    // MARK: Subagents

    static let subagentRow = "subagent-row"
    static let subagentTranscriptClose = "subagent-transcript-close"
}
