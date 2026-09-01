import SwiftUI

/// One tool call, collapsed to a glyph plus `ToolCall.summary` by default.
/// Expanding shows the raw input and result, bounded so a huge result scrolls
/// in place instead of growing the page.
struct ToolCallRow: View {
    @Environment(\.chatFontSize) private var chatFontSize

    let call: ToolCall

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !call.input.isEmpty {
                    inputBody
                }
                if let result = call.result, !result.isEmpty {
                    body(title: "Result", text: result)
                }
            }
            .padding(.top, 4)
        } label: {
            Label(call.summary, systemImage: glyph)
                .font(.system(size: chatFontSize * 0.85))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var inputBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Input")
                .font(.system(size: chatFontSize * 0.75))
                .foregroundStyle(.tertiary)
            ScrollView {
                switch call.input {
                case .code(let language, let text):
                    MarkdownView(blocks: [.codeBlock(language: language, code: text)])
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .json(let text):
                    Text(text)
                        .font(.system(size: chatFontSize * 0.85, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 240)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
            .padding(6)
        }
    }

    private func body(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: chatFontSize * 0.75))
                .foregroundStyle(.tertiary)
            ScrollView {
                Text(text)
                    .font(.system(size: chatFontSize * 0.85, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
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
    }
    .padding()
}
