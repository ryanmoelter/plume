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
                    body(title: "Result", text: result)
                }
                ForEach(call.resultImages.indices, id: \.self) { index in
                    ChatImageView(image: call.resultImages[index])
                }
            }
            .padding(.top, 4)
        } label: {
            Label(call.summary, systemImage: glyph)
                .font(typography.caption.font)
                .emphasis(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .listItemPadding(vertical: false)
    }

    @ViewBuilder
    private var inputBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isDiff ? "Change" : "Input")
                .font(typography.caption.font)
                .emphasis(.subtle)
            switch call.input {
            case .diff(let diff):
                FileDiffView(diff: diff)
            case .code(let language, let text):
                ScrollView {
                    MarkdownView(blocks: [.codeBlock(language: language, code: text)])
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            case .json(let text):
                ScrollView {
                    Text(text)
                        .font(typography.caption.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .background(colors.surfaceTint, in: .rect(cornerRadius: 6))
                .padding(6)
            }
        }
    }

    private var isDiff: Bool {
        if case .diff = call.input { return true }
        return false
    }

    private func body(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(typography.caption.font)
                .emphasis(.subtle)
            ScrollView {
                Text(text)
                    .font(typography.caption.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .background(colors.surfaceTint, in: .rect(cornerRadius: 6))
            .padding(6)
        }
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
            summary: "Bash(ls -la)",
            input: .code(language: "sh", text: "ls -la"),
            result: "total 0\ndrwxr-xr-x  2 user  staff  64 Jan  1 00:00 ."
        ))
        ToolCallRow(call: ToolCall(
            id: "2",
            name: "Read",
            summary: "Read(CLAUDE.md)",
            input: .json("{\"file_path\":\"/Users/me/Plume/CLAUDE.md\"}"),
            result: nil
        ))
        ToolCallRow(
            call: ToolCall(
                id: "3",
                name: "AskUserQuestion",
                summary: "AskUserQuestion",
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
