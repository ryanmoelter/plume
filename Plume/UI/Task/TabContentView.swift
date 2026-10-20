import AppKit
import GhosttyTerminal
import SwiftUI

/// Hosts every tab's terminal at once, showing each pane's selected tab.
///
/// Keeping off-screen tabs mounted (rather than unmounting them) is what
/// keeps their processes alive across tab switches. Panes are placed by
/// frame and padding within one `ForEach`, so a tab moving between panes, or
/// a split opening or closing, never moves a tab's view to another container.
struct TabContentView: View {
    @Bindable var task: WorkTask
    let panes: [[TaskTab]]
    let shown: [UUID]
    /// Follows a divider drag; only on-screen tabs take it, since every
    /// resize of a terminal is a SIGWINCH and a redraw.
    let layout: SplitLayout
    let committedLayout: SplitLayout
    @Binding var draggedFraction: Double?
    @Environment(\.colorScheme) private var colorScheme

    @State private var dropSide: TaskStore.SplitSide?
    @State private var drag = InAppDrag.shared

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if task.tabs.isEmpty {
                    ContentUnavailableView {
                        Label("No Tabs", systemImage: "square.on.square")
                    } description: {
                        Text("Use the + button above to add an agent or terminal tab.")
                    }
                    .themeTint(colorScheme: colorScheme)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                ForEach(panes.flatMap { $0 }) { tab in
                    pane(for: tab, size: proxy.size)
                }
                if let dividerX = layout.dividerX {
                    SplitDivider(x: dividerX) { x in
                        draggedFraction = layout.fraction(forDividerAt: x)
                    } onEnded: {
                        if let draggedFraction { TaskStore.setSplitFraction(draggedFraction, in: task) }
                        draggedFraction = nil
                    } onReset: {
                        draggedFraction = nil
                        TaskStore.setSplitFraction(0.5, in: task)
                    }
                    .frame(height: proxy.size.height)
                    .offset(x: dividerX - SplitDivider.hitWidth / 2)
                }
                if let dropSide {
                    dropHighlight(side: dropSide, size: proxy.size)
                }
                if let draggedTab {
                    SplitDropCatcher(
                        update: { x in
                            let accepts = panes.count > 1 || TaskStore.canOpenInSplit(draggedTab, in: task)
                            dropSide = accepts ? layout.side(forX: x) : nil
                            return accepts
                        },
                        exit: { dropSide = nil },
                        perform: { item, x in
                            guard case .tab(let id) = item,
                                  let tab = task.tabs.first(where: { $0.id == id })
                            else { return }
                            TaskStore.openInSplit(tab, side: layout.side(forX: x), in: task)
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: draggedTab == nil) { _, notDragging in
            if notDragging { dropSide = nil }
        }
    }

    private var draggedTab: TaskTab? {
        guard case .tab(let id) = drag.item else { return nil }
        return task.tabs.first { $0.id == id }
    }

    /// Off-screen tabs keep their pane's committed frame, the size they next
    /// show at.
    private func pane(for tab: TaskTab, size: CGSize) -> some View {
        let isVisible = TabVisibility.isOnScreen(tabID: tab.id, paneTabIDs: shown)
        let placement = (isVisible ? layout : committedLayout).pane(tab.paneIndex)
        let isFocused = TabVisibility.isFocused(tabID: tab.id, selectedTabID: task.selectedTabID)
        let isUnfocusedPane = layout.isSplit && isVisible && !isFocused
        return tabContent(for: tab, isVisible: isVisible, isFocused: isFocused)
            .frame(width: placement?.width ?? size.width, height: size.height)
            .paneAnchored()
            .overlay(alignment: .top) {
                if layout.isSplit, isFocused {
                    Rectangle()
                        .fill(.tint.opacity(0.7))
                        .frame(height: 2)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if isUnfocusedPane {
                    PaneClickProbe(gripXRange: gripXRange(for: placement)) {
                        TaskStore.selectTab(tab, in: task)
                    }
                }
            }
            .plumeID(
                AccessibilityID.tabPane,
                label: tab.displayTitle,
                value: isFocused ? "focused" : nil
            )
            .padding(.leading, placement?.x ?? 0)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .plumeControlsHidden(!isVisible)
    }

    private func gripXRange(for placement: SplitLayout.Pane?) -> ClosedRange<CGFloat>? {
        guard let placement, let dividerX = layout.dividerX else { return nil }
        let center = dividerX - placement.x
        return (center - SplitDivider.hitWidth / 2)...(center + SplitDivider.hitWidth / 2)
    }

    private func dropHighlight(side: TaskStore.SplitSide, size: CGSize) -> some View {
        let split = layout.dividerX ?? (size.width / 2).rounded()
        let x = side == .left ? 0 : split
        let width = side == .left ? split : size.width - split
        return RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.tint, lineWidth: 2)
            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 6))
            .padding(4)
            .frame(width: width, height: size.height)
            .offset(x: x)
            .allowsHitTesting(false)
    }

    /// Only `AgentLauncher` may create an agent tab's surface, since it alone
    /// knows the `claude` command. Creating one here would win the race and
    /// leave the tab running a bare shell.
    @ViewBuilder
    private func tabContent(for tab: TaskTab, isVisible: Bool, isFocused: Bool) -> some View {
        if tab.kind == .agent {
            AgentTabContent(task: task, tab: tab, isVisible: isVisible, isFocused: isFocused)
        } else {
            TerminalTabHost(task: task, tab: tab, isVisible: isVisible, isFocused: isFocused)
        }
    }
}

/// The line between two panes, with a wider invisible grip to drag it by.
private struct SplitDivider: View {
    static let hitWidth: CGFloat = 9

    /// Where the divider sits now, which a drag moves it from.
    let x: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onReset: () -> Void

    @State private var isHovering = false
    @State private var dragStartX: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.separator)
                .frame(width: SplitLayout.dividerWidth)
        }
        .frame(width: Self.hitWidth)
        .contentShape(.rect)
        .gesture(
            // Past a double-click's wobble, so a reset never starts a drag.
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let start = dragStartX ?? x
                    dragStartX = start
                    onChanged(start + value.translation.width)
                }
                .onEnded { _ in
                    dragStartX = nil
                    onEnded()
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
        .plumeHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if isHovering { NSCursor.pop() }
        }
        .plumeID(AccessibilityID.splitDivider, invoke: onReset)
    }
}

/// An agent tab, showing whichever view its transport implies: a headless
/// tab has no PTY and always renders chat; a terminal tab always renders the
/// terminal.
private struct AgentTabContent: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isVisible: Bool
    let isFocused: Bool

    var body: some View {
        switch tab.transport {
        case .headless:
            HeadlessAgentTabContent(task: task, tab: tab, isVisible: isVisible, isFocused: isFocused)
        case .terminal:
            if let session = SurfaceManager.shared.existingSession(for: tab.id) {
                TerminalTabView(session: session, taskID: task.id, tabID: tab.id, isVisible: isVisible, isFocused: isFocused)
            } else if let sessionID = tab.agentSessionID, !sessionID.isEmpty {
                AutoResumingAgentTabView(task: task, tab: tab, isSelected: isVisible, isFocused: isFocused)
            } else {
                AgentFirstMessageView(task: task, tab: tab, isVisible: isVisible, isFocused: isFocused)
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
    let isFocused: Bool

    @State private var hasResumed = false
    @State private var settings = AppSettings.shared

    /// Only on-screen tabs build their chat. Nothing here owns a process —
    /// `AgentSessionManager` does — so unmounting costs a rebuild on the
    /// way back, where staying mounted costs a live `ScrollView` per hidden
    /// tab, each still laying out against a zero-height viewport.
    var body: some View {
        Group {
            if isVisible {
                ChatTabView(task: task, tab: tab, isVisible: isVisible, isFocused: isFocused)
                    .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
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
    let isFocused: Bool

    @State private var session: TerminalSession?

    var body: some View {
        Group {
            if let session {
                TerminalTabView(session: session, taskID: task.id, tabID: tab.id, isVisible: isVisible, isFocused: isFocused)
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
