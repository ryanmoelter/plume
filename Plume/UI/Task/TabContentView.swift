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
                    .plumeControlsHidden(!isVisible)
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

/// An agent tab, showing whichever view its transport implies: a headless
/// tab has no PTY and always renders chat; a terminal tab always renders the
/// terminal.
private struct AgentTabContent: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isVisible: Bool

    var body: some View {
        switch tab.transport {
        case .headless:
            HeadlessAgentTabContent(task: task, tab: tab, isVisible: isVisible)
        case .terminal:
            if let session = SurfaceManager.shared.existingSession(for: tab.id) {
                TerminalTabView(session: session, taskID: task.id, tabID: tab.id, isVisible: isVisible)
            } else if let sessionID = tab.agentSessionID, !sessionID.isEmpty {
                AutoResumingAgentTabView(task: task, tab: tab, isSelected: isVisible)
            } else {
                AgentFirstMessageView(task: task, tab: tab, isVisible: isVisible)
            }
        }
    }
}

/// A headless agent tab: always chat, auto-resuming its session the first
/// time it becomes visible — mirrors `AutoResumingAgentTabView`'s timing, but
/// against `AgentSessionManager` instead of `SurfaceManager`.
private struct HeadlessAgentTabContent: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isVisible: Bool

    @State private var hasResumed = false

    /// Only the visible tab builds its chat. Nothing here owns a process —
    /// `AgentSessionManager` does — so unmounting costs a rebuild on the
    /// way back, where staying mounted costs a live `ScrollView` per hidden
    /// tab, each still laying out against a zero-height viewport.
    var body: some View {
        Group {
            if isVisible {
                ChatTabView(task: task, tab: tab, isVisible: isVisible)
            } else {
                Color.clear
            }
        }
        .onChange(of: isVisible, initial: true) { _, visible in
            guard visible else { return }
            resumeIfNeeded()
        }
        // Picking a conversation to resume sets the ID on a tab that is
        // already visible, so visibility alone would never fire again.
        .onChange(of: tab.agentSessionID) { _, _ in
            guard isVisible else { return }
            resumeIfNeeded()
        }
    }

    private func resumeIfNeeded() {
        guard !hasResumed else { return }
        guard AgentAutoResume.shouldResume(
            agentSessionID: tab.agentSessionID,
            workingDirectoryPath: TabDirectoryStore.shared.directory(for: tab),
            hasExistingSurfaceSession: AgentSessionManager.shared.existingSession(for: tab.id) != nil,
            isSessionWrittenElsewhere: isSessionWrittenElsewhere(),

            directoryExists: { FileManager.default.fileExists(atPath: $0) }
        ) else { return }

        hasResumed = true
        AgentLauncher.launch(message: nil, task: task, tab: tab, resumeSessionID: tab.agentSessionID)
    }

    /// True when an agent orphaned by a previous run is still appending to
    /// this tab's transcript. Resuming on top of one forks the transcript and
    /// leaves both sides blind to the other's turns.
    private func isSessionWrittenElsewhere() -> Bool {
        if tab.provider == .codex {
            return AgentSessionManager.shared.isCodexThreadOwnedElsewhere(tab.agentSessionID, by: tab.id)
        }
        guard
            let sessionID = tab.agentSessionID,
            let workingDirectory = TabDirectoryStore.shared.directory(for: tab)
        else { return false }

        let transcript = SessionJSONLReader.transcriptPath(
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
        let modified = try? FileManager.default
            .attributesOfItem(atPath: transcript)[.modificationDate] as? Date

        return OrphanedSessionDetector.isWrittenElsewhere(
            transcriptModifiedAt: modified ?? nil,
            now: Date(),
            candidatePIDs: ClaudeProcessScanner.plumeLaunchedProcessIDs(),
            ownedPIDs: AgentSessionManager.shared.ownedProcessIdentifiers
        )
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
                TerminalTabView(session: session, taskID: task.id, tabID: tab.id, isVisible: isVisible)
                    .onChange(of: session.title, initial: true) { _, title in
                        // A shell tab's own escape-sequence title is as
                        // authoritative as a source gets, so it ranks the
                        // same as a control-plane reply.
                        TitleStore.shared.setTitle(title, forTab: tab.id, source: .reply)
                    }
                    .onChange(of: session.workingDirectory, initial: true) { _, directory in
                        TabDirectoryStore.shared.setDirectory(directory, forTab: tab)
                    }
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard session == nil else { return }
            // Options are read once at creation, so this places a new tab and
            // never moves a live one.
            session = SurfaceManager.shared.session(
                for: tab.id,
                options: TerminalSurfaceOptions(
                    workingDirectory: TabDirectoryStore.shared.startingDirectory(for: task),
                    envVars: LoginShellCommand.plumeEnvironment,
                    command: LoginShellCommand.loginShell()
                )
            )
        }
    }
}
