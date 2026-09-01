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
            if task.tabs.isEmpty {
                ContentUnavailableView {
                    Label("No Tabs", systemImage: "square.on.square")
                } description: {
                    Text("Use the + button above to add an agent or terminal tab.")
                }
            }
            ForEach(task.orderedTabs) { tab in
                tabContent(for: tab)
                    .opacity(task.selectedTabID == tab.id ? 1 : 0)
                    .allowsHitTesting(task.selectedTabID == tab.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only `AgentLauncher` may create an agent tab's surface, since it alone
    /// knows the `claude` command. Creating one here would win the race and
    /// leave the tab running a bare shell.
    @ViewBuilder
    private func tabContent(for tab: TaskTab) -> some View {
        if tab.kind == .agent {
            if let session = SurfaceManager.shared.existingSession(for: tab.id) {
                TerminalTabView(session: session)
            } else if let sessionID = tab.agentSessionID, !sessionID.isEmpty {
                AgentResumeOverlayView(task: task, tab: tab)
            } else {
                AgentFirstMessageView(task: task, tab: tab)
            }
        } else {
            TerminalTabView(session: terminalSession(for: tab))
        }
    }

    private func terminalSession(for tab: TaskTab) -> TerminalSession {
        SurfaceManager.shared.session(
            for: tab.id,
            options: TerminalSurfaceOptions(
                workingDirectory: task.workingDirectoryPath,
                command: LoginShellCommand.loginShell()
            )
        )
    }
}
