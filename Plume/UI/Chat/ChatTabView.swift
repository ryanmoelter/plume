import SwiftUI

/// The chat rendering of an agent tab: messages, the statusline strip, then
/// the composer.
struct ChatTabView: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isVisible: Bool

    @State private var distanceFromBottom: CGFloat = 0
    @State private var settings = AppSettings.shared

    private var transcript: Transcript? {
        TranscriptStore.shared.transcript(forTab: tab.id)
    }

    private var subagents: [SubagentTranscript] {
        TranscriptStore.shared.subagents(forTab: tab.id)
    }

    private var status: TaskStatus {
        StatusEngine.shared.status(forTab: tab.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let transcript, !transcript.messages.isEmpty {
                messageList(transcript)
                Divider()
                StatuslineStripView(
                    contextUsedTokens: transcript.latestUsage?.inputTokens,
                    contextMaxTokens: nil,
                    model: transcript.model,
                    effort: transcript.effort,
                    branch: transcript.gitBranch,
                    payload: StatuslineStore.shared.payload(forTab: tab.id)
                )
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
        .onChange(of: tab.sessionJSONLPath) { _, _ in registerWatchIfNeeded() }
    }

    private func messageList(_ transcript: Transcript) -> some View {
        let lastMessageID = transcript.messages.last?.id
        let maxWidth = ChatMetrics.maxContentWidth(forFontSize: CGFloat(settings.chatFontSize))
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(transcript.messages) { message in
                        ChatMessageRow(
                            message: message,
                            isLast: ChatScrollAnchor.isEligibleForLiveStatus(
                                messageID: message.id,
                                lastMessageID: lastMessageID
                            ),
                            status: status
                        )
                        .id(message.id)
                    }
                    SubagentListView(subagents: subagents)
                }
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .padding(16)
                .id(bottomAnchorID)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY
            } action: { _, distance in
                distanceFromBottom = max(0, distance)
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
