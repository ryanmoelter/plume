import SwiftUI

/// The chat rendering of an agent tab: messages, the statusline strip, the
/// plan dock when a plan is minimized, then the composer.
struct ChatTabView: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isVisible: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = AppSettings.shared
    @State private var planPresentation = PlanPresentation.closed

    private var transcript: Transcript? {
        TranscriptStore.shared.transcript(forTab: tab.id)
    }

    /// The transcript's plan path is a stale snapshot from when the line was
    /// written, so the file may be gone. The existence check is cached rather
    /// than run inline: this is read from `body`, and touching the filesystem
    /// on every render pass is not free.
    private var planFilePath: String? {
        guard let path = transcript?.planFilePath else { return nil }
        return PlanFileExistence.exists(path) ? path : nil
    }

    private var subagents: [SubagentTranscript] {
        TranscriptStore.shared.subagents(forTab: tab.id)
    }

    /// The transcript's own `cwd` follows the agent, including through
    /// `EnterWorktree`; the task's path only covers the window before any
    /// transcript exists.
    private var gitDirectory: String? {
        transcript?.cwd ?? task.workingDirectoryPath
    }

    private var status: TaskStatus {
        StatusEngine.shared.status(forTab: tab.id)
    }

    private var headlessSession: HeadlessSession? {
        guard tab.transport == .headless else { return nil }
        return HeadlessSessionManager.shared.existingSession(for: tab.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let transcript, !transcript.messages.isEmpty {
                ChatMessageList(
                    messages: transcript.messages,
                    subagents: subagents,
                    status: status,
                    bottomPadding: ChatMetrics.bottomPadding(forFontSize: CGFloat(settings.chatFontSize)),
                    tabID: tab.id
                )
                Divider()
                HStack(spacing: 0) {
                    StatuslineStripView(
                        contextUsedTokens: headlessSession?.contextUsedTokens
                            ?? transcript.latestUsage?.inputTokens,
                        contextMaxTokens: headlessSession?.contextWindow,
                        model: transcript.model,
                        effort: transcript.effort,
                        branch: transcript.gitBranch,
                        gitState: GitStateStore.shared.state(for: gitDirectory),
                        permissionMode: transcript.permissionMode,
                        rateLimit: headlessSession?.rateLimit,
                        sessionCostUSD: headlessSession.flatMap { $0.sessionCostUSD > 0 ? $0.sessionCostUSD : nil },
                        onSelectModel: modelSelectionHandler,
                        onSelectEffort: effortSelectionHandler,
                        onCyclePermissionMode: cyclePermissionModeHandler
                    )
                    if headlessSession?.isWorking == true {
                        stopButton
                    }
                    if let planFilePath, planPresentation != .minimized {
                        planButton(path: planFilePath)
                    }
                }
                .listItemPadding(vertical: false)
                Divider()
                if planPresentation == .minimized, let planFilePath {
                    planDockBar(path: planFilePath)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ChatComposer(task: task, tab: tab, isVisible: isVisible)
            } else if SurfaceManager.shared.existingSession(for: tab.id) != nil
                || HeadlessSessionManager.shared.existingSession(for: tab.id) != nil
                || (tab.agentSessionID?.isEmpty == false) {
                // A process (or a resumable session) exists but has written no
                // transcript content yet — nothing to show but a quiet wait.
                emptyState(showsComposer: false)
            } else {
                emptyState(showsComposer: true)
            }
        }
        .background(ThemeChrome.background(for: colorScheme) ?? Color.clear)
        .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
        .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
        .onAppear { registerWatchIfNeeded() }
        .onChange(of: gitDirectory, initial: true) { previous, current in
            if let previous { GitStateStore.shared.release(previous) }
            if let current { GitStateStore.shared.watch(current) }
        }
        .onDisappear {
            if let gitDirectory { GitStateStore.shared.release(gitDirectory) }
        }
        .onChange(of: tab.sessionJSONLPath) { _, _ in registerWatchIfNeeded() }
        .onChange(of: planFilePath) { _, newPath in
            if newPath == nil { planPresentation = .closed }
        }
        .onChange(of: headlessSession?.sessionID, initial: true) { _, sessionID in
            persistHeadlessSessionID(sessionID)
        }
        .overlay {
            if planPresentation == .expanded, let planFilePath {
                planPanel(path: planFilePath)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: planPresentation)
    }

    private func planButton(path: String) -> some View {
        Button {
            planPresentation = .expanded
        } label: {
            Label("Plan", systemImage: "doc.text")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .emphasis(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// A wash of the chat's own surface, so the glass reads as the chat holding
    /// a document rather than a system panel floating over it. Nil leaves the
    /// glass untinted, which is still legible.
    private var planTint: Color? {
        ThemeChrome.background(for: colorScheme)?.opacity(0.5)
    }

    private func planPanel(path: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text((path as NSString).lastPathComponent)
                    .font(.headline)
                Spacer()
                Button {
                    planPresentation = .minimized
                } label: {
                    Image(systemName: "chevron.down")
                        .emphasis(.secondary)
                }
                .buttonStyle(.plain)
                .help("Minimize")
                Button {
                    planPresentation = .closed
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .emphasis(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(12)
            Divider()
            MarkdownFileView(path: path)
        }
        .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
        .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
        .glassEffect(planGlass, in: .rect(cornerRadius: 12))
        .listItemPadding(bleed: true)
        .padding(.vertical, 8)
    }

    private func planDockBar(path: String) -> some View {
        HStack(spacing: 8) {
            // The whole row expands, so the target is the bar rather than just
            // the chevron; close stays a sibling so it isn't a nested button.
            Button {
                planPresentation = .expanded
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .emphasis(.secondary)
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .emphasis(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Expand the plan")

            Button {
                planPresentation = .closed
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .emphasis(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(planGlass, in: .rect(cornerRadius: 10))
        .listItemPadding(bleed: true, vertical: false)
        .padding(.top, 8)
    }

    private var planGlass: Glass {
        planTint.map { Glass.regular.tint($0) } ?? .regular
    }

    private func emptyState(showsComposer: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .emphasis(.secondary)
            Text(showsComposer ? "Start a conversation" : "Waiting for the first message…")
                .font(.headline)
                .emphasis(.secondary)
            Spacer()
            if showsComposer {
                ChatComposer(task: task, tab: tab, isVisible: isVisible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func registerWatchIfNeeded() {
        guard let path = tab.sessionJSONLPath, !path.isEmpty else { return }
        TranscriptStore.shared.watch(tabID: tab.id, transcriptPath: path)
    }

    /// The TUI path learns these from hook events; headless has no hooks, so
    /// the stream's own `session_id` is the only source. Persisted so resume
    /// survives an app restart and so the chat has a transcript to read.
    private func persistHeadlessSessionID(_ sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty, tab.agentSessionID != sessionID else { return }
        tab.agentSessionID = sessionID
        guard let workingDirectory = task.workingDirectoryPath else { return }
        tab.sessionJSONLPath = SessionJSONLReader.transcriptPath(
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
    }

    private var modelSelectionHandler: ((AgentModel) -> Void)? {
        if let headlessSession {
            return { headlessSession.setModel($0) }
        }
        return SurfaceManager.shared.existingSession(for: tab.id).map { session in
            { session.submit(text: ModelEffortCommand.setModel($0)) }
        }
    }

    private var effortSelectionHandler: ((AgentEffort) -> Void)? {
        if let headlessSession {
            return { headlessSession.submit(text: ModelEffortCommand.setEffort($0)) }
        }
        return SurfaceManager.shared.existingSession(for: tab.id).map { session in
            { session.submit(text: ModelEffortCommand.setEffort($0)) }
        }
    }

    /// Headless has no Shift+Tab to cycle; `set_permission_mode` sets a mode
    /// outright, so this just steps to the next one in declaration order.
    private var cyclePermissionModeHandler: (() -> Void)? {
        if let headlessSession {
            return {
                let modes = PermissionMode.allCases
                let current = transcript?.permissionMode.flatMap(PermissionMode.recognizing)
                let currentIndex = current.flatMap { modes.firstIndex(of: $0) } ?? -1
                let next = modes[(currentIndex + 1) % modes.count]
                headlessSession.setPermissionMode(next)
            }
        }
        return SurfaceManager.shared.existingSession(for: tab.id).map { session in
            { session.cyclePermissionMode() }
        }
    }

    private var stopButton: some View {
        Button {
            headlessSession?.interrupt()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .emphasis(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .help("Stop the current turn")
    }
}
