import SwiftUI

/// Whether a task's context menu should offer to toggle Remote Control, and
/// which tab it would act on.
///
/// Only Claude Code's headless transport carries the bridge — a terminal
/// tab's own TUI already has a working `/rc`, and Codex has no equivalent
/// this toggle can drive without its own setup flow. A task with more than
/// one agent tab has no single tab for the toggle to mean, so it needs
/// exactly one.
enum TaskRemoteControl {
    static func toggleableTab(in task: WorkTask) -> TaskTab? {
        let agentTabs = task.orderedTabs.filter { $0.kind == .agent }
        guard agentTabs.count == 1, let tab = agentTabs.first,
              tab.provider == .claudeCode, tab.transport == .headless
        else { return nil }
        return tab
    }
}

/// The task context menu's Remote Control toggle, shown only when
/// `TaskRemoteControl.toggleableTab` finds a tab for it to act on.
struct TaskRemoteControlToggle: View {
    let tabID: UUID

    private var session: HeadlessSession? {
        AgentSessionManager.shared.existingSession(for: tabID) as? HeadlessSession
    }

    var body: some View {
        Toggle("Remote Control", isOn: Binding(
            get: { session?.isRemotelyControlled ?? false },
            set: { session?.setRemoteControl(enabled: $0) }
        ))
        // Nothing to toggle before the tab's agent has ever run.
        .disabled(session == nil)
        .plumeID(AccessibilityID.taskRemoteControlToggle)
    }
}
