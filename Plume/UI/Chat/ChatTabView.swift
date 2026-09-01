import SwiftUI

/// The chat rendering of an agent tab: messages, the statusline strip, then
/// the composer.
struct ChatTabView: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isVisible: Bool

    @State private var distanceFromBottom: CGFloat = 0
    @State private var settings = AppSettings.shared
    @State private var isShowingPlan = false

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

    var body: some View {
        VStack(spacing: 0) {
            if let transcript, !transcript.messages.isEmpty {
                messageList(transcript)
                Divider()
                HStack(spacing: 0) {
                    StatuslineStripView(
                        contextUsedTokens: transcript.latestUsage?.inputTokens,
                        contextMaxTokens: nil,
                        model: transcript.model,
                        effort: transcript.effort,
                        branch: transcript.gitBranch,
                        gitState: GitStateStore.shared.state(for: gitDirectory),
                        permissionMode: transcript.permissionMode,
                        payload: StatuslineStore.shared.payload(forTab: tab.id),
                        onSelectModel: SurfaceManager.shared.existingSession(for: tab.id).map { session in
                            { session.submit(text: ModelEffortCommand.setModel($0)) }
                        },
                        onSelectEffort: SurfaceManager.shared.existingSession(for: tab.id).map { session in
                            { session.submit(text: ModelEffortCommand.setEffort($0)) }
                        },
                        onCyclePermissionMode: SurfaceManager.shared.existingSession(for: tab.id).map { session in
                            { session.cyclePermissionMode() }
                        }
                    )
                    if let planFilePath {
                        planButton(path: planFilePath)
                    }
                }
                .frame(maxWidth: ChatMetrics.maxContentWidth(forFontSize: CGFloat(settings.chatFontSize)))
                .frame(maxWidth: .infinity)
                Divider()
                ChatComposer(task: task, tab: tab, isVisible: isVisible)
            } else if SurfaceManager.shared.existingSession(for: tab.id) != nil || (tab.agentSessionID?.isEmpty == false) {
                // A process (or a resumable session) exists but has written no
                // transcript content yet — nothing to show but a quiet wait.
                emptyState(showsComposer: false)
            } else {
                emptyState(showsComposer: true)
            }
        }
        .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
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
            if newPath == nil { isShowingPlan = false }
        }
        .overlay(alignment: .trailing) {
            if isShowingPlan, let planFilePath {
                planPanel(path: planFilePath)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private func planButton(path: String) -> some View {
        Button {
            isShowingPlan = true
        } label: {
            Label("Plan", systemImage: "doc.text")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func planPanel(path: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text((path as NSString).lastPathComponent)
                    .font(.headline)
                Spacer()
                Button {
                    isShowingPlan = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            MarkdownFileView(path: path)
        }
        .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Divider()
        }
        .shadow(color: .black.opacity(0.2), radius: 12, x: -2, y: 0)
    }

    private func messageList(_ transcript: Transcript) -> some View {
        let lastMessageID = transcript.messages.last?.id
        let maxWidth = ChatMetrics.maxContentWidth(forFontSize: CGFloat(settings.chatFontSize))
        return ScrollViewReader { proxy in
            ScrollView {
                // Lazy so a long transcript only builds the rows on screen.
                // A plain VStack lays out every message on every pass, which
                // is thousands of markdown parses per frame on a real
                // conversation.
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(transcript.messages) { message in
                        // Only the newest row reflects live status, so only
                        // it reads `status`. Passing it to every row made a
                        // status change invalidate the whole list, which
                        // rebuilds rows the lazy stack had already built.
                        let isLast = ChatScrollAnchor.isEligibleForLiveStatus(
                            messageID: message.id,
                            lastMessageID: lastMessageID
                        )
                        ChatMessageRow(
                            message: message,
                            isLast: isLast,
                            status: isLast ? status : .unset
                        )
                        .id(message.id)
                    }
                    SubagentListView(subagents: subagents)
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .padding(16)
                .padding(.bottom, ChatMetrics.bottomPadding(forFontSize: CGFloat(settings.chatFontSize)))
            }
            .onScrollGeometryChange(for: ChatScrollGeometry.self) { geometry in
                ChatScrollGeometry(
                    distanceFromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                    contentHeight: geometry.contentSize.height
                )
            } action: { old, new in
                distanceFromBottom = new.distanceFromBottom
                guard ChatScrollAnchor.shouldFollowGrowth(
                    previousDistanceFromBottom: old.distanceFromBottom,
                    previousContentHeight: old.contentHeight,
                    newContentHeight: new.contentHeight
                ) else { return }
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: lastMessageID) { _, newID in
                guard newID != nil else { return }
                if ChatScrollAnchor.shouldAutoScroll(distanceFromBottom: distanceFromBottom) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func emptyState(showsComposer: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(showsComposer ? "Start a conversation" : "Waiting for the first message…")
                .font(.headline)
                .foregroundStyle(.secondary)
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

    private let bottomAnchorID = "chat-bottom-anchor"
}
