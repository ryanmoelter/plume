import GhosttyTerminal
import SwiftUI

/// Hosts every tab's terminal at once, showing only the selected one.
///
/// Keeping non-selected tabs mounted (rather than unmounting them) is what
/// keeps their processes alive across tab switches.
struct TabContentView: View {
    @Bindable var task: WorkTask
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if task.tabs.isEmpty {
                ContentUnavailableView {
                    Label("No Tabs", systemImage: "square.on.square")
                } description: {
                    Text("Use the + button above to add an agent or terminal tab.")
                }
                .themeTint(colorScheme: colorScheme)
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
                AutoResumingAgentTabView(task: task, tab: tab, isSelected: task.selectedTabID == tab.id)
            } else {
                AgentFirstMessageView(task: task, tab: tab)
            }
        } else {
            TerminalTabHost(task: task, tab: tab)
        }
    }
}

/// Owns one terminal tab's session, so the surface lookup and the title
/// reporting happen outside `body`.
///
/// Both write shared state — `SurfaceManager`'s task association and
/// `TitleStore`'s titles — and a write to `@Observable` state during a body
/// evaluation invalidates the very view being rendered, which spins the
/// render loop.
private struct TerminalTabHost: View {
    let task: WorkTask
    let tab: TaskTab

    @State private var session: TerminalSession?

    var body: some View {
        Group {
            if let session {
                TerminalTabView(session: session)
                    .onChange(of: session.title, initial: true) { _, title in
                        TitleStore.shared.setTitle(title, forTab: tab.id)
                    }
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard session == nil else { return }
            session = SurfaceManager.shared.session(
                for: tab.id,
                options: TerminalSurfaceOptions(
                    workingDirectory: task.workingDirectoryPath,
                    command: LoginShellCommand.loginShell()
                )
            )
        }
    }
}
