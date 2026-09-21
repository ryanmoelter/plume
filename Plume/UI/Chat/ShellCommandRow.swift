import SwiftUI

/// A shell command run from the composer with `!`, and what it printed.
///
/// Prominent rather than a one-line marker: the user ran this deliberately,
/// and its output is often what the next turn is about. Centered at content
/// width instead of on either margin, since it is neither the user's prose
/// nor the agent's.
///
/// A line can carry the command, the output, or both — Claude Code's own bash
/// mode writes two transcript lines where Plume's command mode sends one, so
/// each half draws only when it is there.
struct ShellCommandRow: View, ThemedView {
    @Environment(\.theme) var theme

    let shell: ShellTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command = shell.command {
                CodeSegmentView(
                    segment: CodeSegment(language: "bash", code: command),
                    title: "input",
                    bleeds: false
                )
            }
            if let output = shell.output {
                CodeSegmentView(segment: CodeSegment(code: output), title: "output", bleeds: false)
            }
        }
        .padding(8)
        .background(colors.surfaceTint, in: .rect(cornerRadius: 10))
        .frame(maxWidth: dimensions.contentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .listItemPadding(vertical: false)
    }
}
