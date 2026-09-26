import SwiftUI

/// Whether a task's context menu should offer to toggle Remote Control, and
/// which tab it would act on.
///
/// Only the headless transport qualifies — a terminal tab runs its CLI's own
/// TUI, which offers remote control itself. A task with more than one agent tab has no
/// single tab for the toggle to mean, so it needs exactly one.
enum TaskRemoteControl {
    static func toggleableTab(in task: WorkTask) -> TaskTab? {
        let agentTabs = task.orderedTabs.filter { $0.kind == .agent }
        guard agentTabs.count == 1, let tab = agentTabs.first, tab.transport == .headless
        else { return nil }
        return tab
    }
}

/// The task context menu's Remote Control toggle, shown only when
/// `TaskRemoteControl.toggleableTab` finds a tab for it to act on.
///
/// Codex pairing stays in the statusline's Remote Control menu: turning the
/// host on needs no paired device, so the toggle never opens that sheet.
struct TaskRemoteControlToggle: View {
    let tabID: UUID

    private var session: (any AgentSession)? {
        AgentSessionManager.shared.existingSession(for: tabID)
    }

    private var codexRemote: CodexRemoteControl? {
        (session as? CodexSession)?.effectiveRemoteControl
    }

    private var isOn: Bool {
        if let codexRemote { return codexRemote.isAvailableForRemoteAccess }
        return session?.isRemotelyControlled ?? false
    }

    private func setEnabled(_ enabled: Bool) {
        if let codexRemote {
            Task { await codexRemote.setEnabled(enabled) }
        } else {
            (session as? HeadlessSession)?.setRemoteControl(enabled: enabled)
        }
    }

    var body: some View {
        Toggle("Remote Control", isOn: Binding(get: { isOn }, set: setEnabled))
            .plumeID(AccessibilityID.taskRemoteControlToggle)
            // Nothing to toggle before the tab's agent has run, or once it's exited.
            .disabled(session == nil || session?.hasExited == true || codexRemote?.operation == .disabling)
    }
}
