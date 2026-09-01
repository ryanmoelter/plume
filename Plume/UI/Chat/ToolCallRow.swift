import SwiftUI

/// One tool call, collapsed to a glyph plus `ToolCall.summary` by default.
/// Expanding shows the raw input and result, bounded so a huge result scrolls
/// in place instead of growing the page.
struct ToolCallRow: View {
    let call: ToolCall

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !call.prettyInput.isEmpty && call.prettyInput != "{}" {
                    body(title: "Input", text: call.prettyInput)
                }
                if let result = call.result, !result.isEmpty {
                    body(title: "Result", text: result)
                }
            }
            .padding(.top, 4)
        } label: {
            Label(call.summary, systemImage: glyph)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func body(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
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
    ToolCallRow(call: ToolCall(
        id: "1",
        name: "Bash",
        summary: "Bash(ls -la)",
        prettyInput: "{\"command\":\"ls -la\"}",
        result: "total 0\ndrwxr-xr-x  2 user  staff  64 Jan  1 00:00 ."
    ))
    .padding()
}
