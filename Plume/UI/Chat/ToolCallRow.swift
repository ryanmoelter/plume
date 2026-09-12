import SwiftUI

/// One tool call, collapsed to a glyph plus `ToolCall.summary` by default.
/// Expanding shows the raw input and result, bounded so a huge result scrolls
/// in place instead of growing the page.
struct ToolCallRow: View, ThemedView {
    @Environment(\.theme) var theme

    let call: ToolCall
    /// Whether the agent is still waiting on this call, passed down so a
    /// pending plan or question reads as live.
    var isPending: Bool = false

    @State private var expanded = false

    var body: some View {
        if let interactive = call.interactive {
            InteractiveToolRow(payload: interactive, isPending: isPending, resultText: call.result)
        } else {
            collapsibleBody
        }
    }

    private var collapsibleBody: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !call.input.isEmpty {
                    inputBody
                }
                if let result = call.result, !result.isEmpty {
                    resultBody(result)
                }
                ForEach(call.resultImages.indices, id: \.self) { index in
                    ChatImageView(image: call.resultImages[index])
                }
            }
            .padding(.top, 4)
        } label: {
            Label {
                Text(summaryText)
            } icon: {
                Image(systemName: glyph)
            }
                .font(typography.caption.font)
                .emphasis(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .listItemPadding(vertical: false)
        .chatItemExpansionProbe(expanded)
    }

    /// The one-liner: the tool's name in prose, then the detail it carries in
    /// whichever face suits it. The trailing marker is unconditional — it
    /// stands for the input this row hides, not for elided text.
    private var summaryText: AttributedString {
        var text = AttributedString(call.summary.name)
        guard let detail = call.summary.detail else { return text }
        text.append(AttributedString(": "))
        var tail = AttributedString("\(detail)…")
        if call.summary.detailStyle == .code {
            tail.font = typography.caption.mono
        }
        text.append(tail)
        return text
    }

    @ViewBuilder
    private var inputBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(inputTitle)
            switch call.input {
            case .diff(let diff):
                FileDiffView(diff: diff)
            case .code(let language, let text):
                ScrollView {
                    MarkdownView(blocks: [.codeBlock(language: language, code: text)])
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: ChatPieceMetrics.maxDisclosedHeight)
            case .json(let text):
                ScrollView {
                    Text(text)
                        .font(typography.caption.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: ChatPieceMetrics.maxDisclosedHeight)
                .background(colors.surfaceTint, in: .rect(cornerRadius: 6))
                .padding(6)
            }
        }
    }

    /// What the agent sent. A shell command is named as one, since the row
    /// then shows it as the code it is.
    private var inputTitle: String {
        switch call.input {
        case .diff: "Change"
        case .code where call.name == "Bash": "Command"
        case .code, .json: "Input"
        }
    }

    /// What came back, drawn unlike the input above it: outlined and secondary
    /// rather than filled, so a command and its output never read as one pair
    /// of matching blocks.
    private func resultBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(call.name == "Bash" ? "Output" : "Result")
            ScrollView {
                Text(text)
                    .font(typography.caption.mono)
                    .emphasis(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: ChatPieceMetrics.maxDisclosedHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(colors.divider, lineWidth: 1)
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(typography.caption.font)
            .emphasis(.subtle)
    }

    private var glyph: String {
        switch call.name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Write", "Edit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "Agent": "person.2"
        case "Skill": "sparkles"
        case "WebFetch", "WebSearch": "globe"
        default: "wrench.and.screwdriver"
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ToolCallRow(call: ToolCall(
            id: "1",
            name: "Bash",
            summary: ToolCallSummary(name: "Bash", detail: "ls -la"),
            input: .code(language: "sh", text: "ls -la"),
            result: "total 0\ndrwxr-xr-x  2 user  staff  64 Jan  1 00:00 ."
        ))
        ToolCallRow(call: ToolCall(
            id: "2",
            name: "Read",
            summary: ToolCallSummary(name: "Read", detail: "CLAUDE.md"),
            input: .json("{\"file_path\":\"/Users/me/Plume/CLAUDE.md\"}"),
            result: nil
        ))
        ToolCallRow(
            call: ToolCall(
                id: "3",
                name: "AskUserQuestion",
                summary: ToolCallSummary(name: "AskUserQuestion"),
                input: .json("{}"),
                interactive: .questions([
                    .init(
                        header: "Scope",
                        question: "How much should this cover?",
                        multiSelect: false,
                        options: [
                            .init(label: "Just the parser", description: "Smallest reviewable slice"),
                            .init(label: "Everything", description: "All five roadmap items"),
                        ]
                    )
                ]),
                result: nil
            ),
            isPending: true
        )
    }
    .padding()
}
