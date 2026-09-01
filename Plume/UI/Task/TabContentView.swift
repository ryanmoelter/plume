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
                let isVisible = TabVisibility.isOnScreen(
                    tabID: tab.id, selectedTabID: task.selectedTabID
                )
                tabContent(for: tab, isVisible: isVisible)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only `AgentLauncher` may create an agent tab's surface, since it alone
    /// knows the `claude` command. Creating one here would win the race and
    /// leave the tab running a bare shell.
    @ViewBuilder
    private func tabContent(for tab: TaskTab, isVisible: Bool) -> some View {
        if tab.kind == .agent {
            AgentTabContent(task: task, tab: tab, isVisible: isVisible)
        } else {
            TerminalTabHost(task: task, tab: tab, isVisible: isVisible)
        }
    }
}

/// An agent tab in both its renderings at once, showing whichever the tab's
/// render mode selects.
///
/// Both stay mounted for the same reason every tab does: the terminal owns the
/// PTY, so unmounting it to show the chat would kill the agent.
private struct AgentTabContent: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isVisible: Bool

    private var showsChat: Bool {
        tab.renderMode == .chat
    }

    var body: some View {
        ZStack {
            terminal
                .opacity(showsChat ? 0 : 1)
                .allowsHitTesting(isVisible && !showsChat)

            if isVisible && showsChat {
                ChatTabView(task: task, tab: tab, isVisible: isVisible)
            }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        if let session = SurfaceManager.shared.existingSession(for: tab.id) {
            // The chat drives focus while it is showing, so the terminal must
            // not also claim it.
            TerminalTabView(session: session, isVisible: isVisible && !showsChat)
        } else if let sessionID = tab.agentSessionID, !sessionID.isEmpty {
            AutoResumingAgentTabView(task: task, tab: tab, isSelected: isVisible)
        } else {
            AgentFirstMessageView(task: task, tab: tab, isVisible: isVisible && !showsChat)
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
    let isVisible: Bool

    @State private var session: TerminalSession?

    var body: some View {
        Group {
            if let session {
                TerminalTabView(session: session, isVisible: isVisible)
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
