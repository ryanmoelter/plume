import GhosttyTerminal
import SwiftUI

/// Hosts every tab's terminal at once, showing only the selected one.
///
/// Keeping non-selected tabs mounted (rather than unmounting them) is what
/// keeps their processes alive across tab switches.
struct TabContentView: View {
    @Bindable var task: WorkTask

    var body: some View {
        ZStack {
            ForEach(task.orderedTabs) { tab in
                tabContent(for: tab)
                    .opacity(task.selectedTabID == tab.id ? 1 : 0)
                    .allowsHitTesting(task.selectedTabID == tab.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tabContent(for tab: TaskTab) -> some View {
        if tab.kind == .agent, SurfaceManager.shared.existingSession(for: tab.id) == nil {
            if let sessionID = tab.agentSessionID, !sessionID.isEmpty {
                AgentResumeOverlayView(task: task, tab: tab)
            } else {
                AgentFirstMessageView(task: task, tab: tab)
            }
        } else {
            TerminalTabView(session: session(for: tab))
        }
    }

    private func session(for tab: TaskTab) -> TerminalSession {
        SurfaceManager.shared.session(
            for: tab.id,
            options: TerminalSurfaceOptions(workingDirectory: task.workingDirectoryPath)
        )
    }
}
