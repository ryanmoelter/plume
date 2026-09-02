import SwiftUI

/// One message in the chat, with the roadmap's two treatments: a quiet,
/// indented wash for the user, full-width prose for Claude.
struct ChatMessageRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var chatFontSize

    let message: ChatMessage
    /// Whether this is the newest message, so it's eligible for the
    /// in-progress / needs-input treatment.
    let isLast: Bool
    let status: TaskStatus
    /// Tool-use ids the headless session is stalled on, which the pending
    /// dock draws with live controls. Empty on the TUI transport, which has
    /// no such signal.
    var pendingToolUseIDs: Set<String> = []
    /// Live text for the turn in flight, drawn after this message's own
    /// blocks. Only ever set on the last message.
    var streaming = ChatStreamHandoff.Overlay()

    private var isWorking: Bool {
        isLast && status == .working
    }

    private var needsInput: Bool {
        isLast && status == .needsInput
    }

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userBody
            case .assistant:
                assistantBody
            case .notice:
                noticeBody
            }
        }
    }

    /// An injected line is not the user speaking, so it skips the bubble and
    /// its right-hand indent and sits full-width like the transcript's own
    /// asides.
    private var isInjectedOnly: Bool {
        !message.blocks.isEmpty && message.blocks.allSatisfy { block in
            if case .injected = block { return true }
            return false
        }
    }

    private var userBody: some View {
        Group {
            if isInjectedOnly {
                VStack(alignment: .leading, spacing: 8) {
                    blocks
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // The wash sits directly on the blocks, and the frames only
                // position the result. Bounded text wraps and reports the width
                // it actually used, so the bubble hugs a short message and still
                // wraps a long one at reading measure. A container between the
                // two would instead accept the full width on offer, which is
                // what made a two-word message as wide as a paragraph.
                VStack(alignment: .leading, spacing: 8) {
                    blocks
                }
                .environment(\.chatHugsContent, true)
                .padding(10)
                .background(washColor, in: .rect(cornerRadius: 10))
                .frame(maxWidth: ChatMetrics.maxContentWidth(forFontSize: chatFontSize), alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        // What the user typed reads as input, not as published prose, so it
        // keeps the system face while the agent's replies take the serif.
        .environment(\.chatProseFace, .system)
    }

    private var noticeBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            blocks
        }
        .padding(.vertical, 4)
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            blocks
            if !streaming.isEmpty {
                StreamingBlocks(overlay: streaming)
            }
            if isWorking {
                WorkingIndicator()
                    .listItemPadding(vertical: false)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, needsInput ? 10 : 0)
        .background(needsInput ? attentionWash : Color.clear, in: .rect(cornerRadius: 10))
        .overlay {
            if needsInput {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(attentionBorder, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var blocks: some View {
        ForEach(message.blocks.indices, id: \.self) { index in
            switch message.blocks[index] {
            case .markdown(let text):
                MarkdownView(text)
            case .thinking(let text):
                ThinkingRow(text: text)
            case .toolCall(let call):
                // The dock already draws this one, answerable.
                if !pendingToolUseIDs.contains(call.id) {
                    ToolCallRow(call: call, isPending: isPendingBlock(at: index))
                }
            case .injected(let kind, let text):
                InjectedContentRow(kind: kind, text: text)
            case .notice(let notice):
                ChatNoticeRow(notice: notice)
            case .image(let image):
                ChatImageView(image: image)
            }
        }
    }

    /// The positional guess, for the TUI transport. Headless, a stalled call
    /// is named exactly and the dock draws it instead.
    private func isPendingBlock(at index: Int) -> Bool {
        needsInput && index == message.blocks.count - 1
    }

    private var washColor: Color {
        .chatSurface(.backgroundTint, colorScheme: colorScheme)
    }

    private var attentionWash: Color {
        ChatRole.attention.emphasized(.backgroundTint, colorScheme: colorScheme)
    }

    private var attentionBorder: Color {
        ChatRole.attention.emphasized(.disabled, colorScheme: colorScheme)
    }
}

/// Local re-export of the sidebar's pulsing dot, sized for inline use next to
/// prose rather than a status list.
private struct WorkingIndicator: View {
    @Environment(\.chatFontSize) private var chatFontSize

    var body: some View {
        HStack(spacing: 6) {
            // `TimelineView` rather than an animation modifier. Both
            // `phaseAnimator` and a `repeatForever` opacity animation drive a
            // display-list rebuild for every tick, and this dot lives in the
            // same stack as the message list — a trace showed those ticks
            // rebuilding the whole chat tree ~37,000 times over 15 seconds.
            // Deriving opacity from the clock keeps the redraw to this view.
            TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
                Circle()
                    .fill(ChatRole.activity)
                    .opacity(Self.opacity(at: context.date))
            }
            .frame(width: 7, height: 7)
            Text("Working…")
                .font(.system(size: chatFontSize * 0.8))
                .emphasis(.secondary)
        }
    }

    private static let pulsePeriod: TimeInterval = 1.4

    /// A smooth 1.0 → 0.3 → 1.0 pulse from wall-clock time, so the phase does
    /// not restart when a recycled row remounts.
    private static func opacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod
        return 0.65 + 0.35 * cos(phase * 2 * .pi)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ChatMessageRow(
            message: ChatMessage(id: "1", role: .user, blocks: [.markdown("Fix the build")], timestamp: nil),
            isLast: false,
            status: .idle
        )
        ChatMessageRow(
            message: ChatMessage(id: "2", role: .assistant, blocks: [.markdown("Working on it.")], timestamp: nil),
            isLast: true,
            status: .working
        )
        ChatMessageRow(
            message: ChatMessage(id: "3", role: .assistant, blocks: [.markdown("Should I proceed?")], timestamp: nil),
            isLast: true,
            status: .needsInput
        )
    }
    .padding()
    .frame(width: 500)
}
