import SwiftUI

/// A shell command and what it printed: run from the composer with `!`, or
/// disclosed from the agent's own `Bash` tool call.
///
/// Prominent rather than a one-line marker: the user ran this deliberately,
/// and its output is often what the next turn is about.
///
/// The two code blocks carry the whole row — each already draws its own
/// surface and header, so wrapping them in a bubble only stacked a second
/// tint behind blocks that had one.
///
/// They meet as one shape: no gap, and the edge they share is square, so the
/// command and what it printed read as a single unit rather than two blocks
/// that happen to be adjacent. The output is outlined in the same color the
/// input is filled with, so it reads as the quieter half of one thing — a
/// lighter distinction than prose has, for something that is neither the
/// user's voice nor the agent's.
///
/// A line can carry the command, the output, or both — Claude Code's own bash
/// mode writes two transcript lines where Plume's command mode sends one, so
/// each half draws only when it is there, and a half standing alone keeps all
/// four corners.
struct ShellCommandRow: View {
    let shell: ShellTranscript
    /// False inside a row that owns its own width and padding, which is how
    /// a disclosed tool call hosts this.
    var bleeds = true
    /// Caps each half, scrolling it in place past that. A `!` command leaves
    /// it nil and grows to fit; a tool call's result is the agent's own and
    /// can be a whole build log, so it is bounded.
    var maxHeight: CGFloat?

    private var hasBoth: Bool { shell.command != nil && output != nil }

    /// A failing command with nothing on either stream still has its exit
    /// code to report, so the output half draws an empty block rather than
    /// vanishing and leaving the failure unsaid.
    private var output: String? {
        if let output = shell.output { return output }
        return shell.didFail ? "" : nil
    }

    /// `error • exit 1`, or plain `error` when no exit code was recorded —
    /// Claude Code's own bash mode writes none.
    private var outputTitle: String {
        guard shell.didFail else { return "output" }
        guard let exitCode = shell.exitCode else { return "error" }
        return "error \u{2022} exit \(exitCode)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let command = shell.command {
                CodeSegmentView(
                    segment: CodeSegment(language: "bash", code: command),
                    title: "bash command",
                    bleeds: bleeds,
                    joins: hasBoth ? .below : .alone,
                    maxHeight: maxHeight
                )
            }
            if let output {
                CodeSegmentView(
                    segment: CodeSegment(code: output),
                    title: outputTitle,
                    bleeds: bleeds,
                    joins: hasBoth ? .above : .alone,
                    isOutlined: true,
                    isFailure: shell.didFail,
                    maxHeight: maxHeight
                )
            }
        }
    }
}
