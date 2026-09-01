import SwiftUI

/// One message in the chat, with the roadmap's two treatments: a quiet,
/// indented wash for the user, full-width prose for Claude.
struct ChatMessageRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let message: ChatMessage
    /// Whether this is the newest message, so it's eligible for the
    /// in-progress / needs-input treatment.
    let isLast: Bool
    let status: TaskStatus

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
                HStack {
                    Spacer(minLength: 48)
                    VStack(alignment: .leading, spacing: 8) {
                        blocks
                    }
                    .padding(10)
                    .background(washColor, in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            blocks
            if isWorking {
                WorkingIndicator()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, needsInput ? 10 : 0)
        .background(needsInput ? Color.orange.opacity(0.1) : Color.clear, in: .rect(cornerRadius: 10))
        .overlay {
            if needsInput {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var blocks: some View {
        ForEach(Array(message.blocks.enumerated()), id: \.offset) { index, block in
            switch block {
            case .markdown(let text):
                MarkdownView(text)
            case .thinking(let text):
                ThinkingRow(text: text)
            case .toolCall(let call):
                ToolCallRow(call: call, isPending: isPendingBlock(at: index))
            case .injected(let kind, let text):
                InjectedContentRow(kind: kind, text: text)
            }
        }
    }

    /// A plan or question is still live only as the final block of the newest
    /// message, while the agent is waiting.
    private func isPendingBlock(at index: Int) -> Bool {
        needsInput && index == message.blocks.count - 1
    }

    private var washColor: Color {
        (ThemeChrome.foreground(for: colorScheme) ?? .primary).opacity(0.08)
    }
}

/// Local re-export of the sidebar's pulsing dot, sized for inline use next to
/// prose rather than a status list.
private struct WorkingIndicator: View {
    @Environment(\.chatFontSize) private var chatFontSize
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.blue)
                .frame(width: 7, height: 7)
                .opacity(pulsing ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
            Text("Working…")
                .font(.system(size: chatFontSize * 0.8))
                .foregroundStyle(.secondary)
        }
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
