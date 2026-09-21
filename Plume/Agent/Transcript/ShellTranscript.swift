import Foundation

/// The command and output inside a bash-mode user line.
///
/// Claude Code's own bash mode writes the command and its output as two
/// transcript lines; Plume's command mode sends both in one message, so a
/// line can carry either half or both. What is present decides what the row
/// renders, so both halves are optional.
nonisolated struct ShellTranscript: Equatable {
    var command: String?
    /// stdout and stderr as one block, in that order — the streams are kept
    /// apart on the wire for the agent, but a reader wants the run's output
    /// in the order the shell printed it.
    var output: String?

    /// Whether the command wrote anything to stderr.
    ///
    /// The transcript records no exit code — `CommandModeResult` leaves it
    /// out — so this is the only failure signal a parsed line carries. It
    /// over-reports: plenty of commands write progress to stderr and exit
    /// zero. A tool call knows better and passes its own `is_error`.
    var didFail = false

    var isEmpty: Bool { command == nil && output == nil }

    static func parse(_ text: String) -> ShellTranscript {
        let streams = [tagged(text, "bash-stdout"), tagged(text, "bash-stderr")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let stderr = tagged(text, "bash-stderr")
        return ShellTranscript(
            command: tagged(text, "bash-input"),
            output: streams.isEmpty ? nil : streams.joined(separator: "\n"),
            didFail: !(stderr ?? "").isEmpty
        )
    }

    private static func tagged(_ text: String, _ tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
