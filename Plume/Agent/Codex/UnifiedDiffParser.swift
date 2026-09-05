import Foundation

/// Turns Codex's unified-diff strings into the same line model the chat uses.
///
/// This deliberately does not use `FileDiffBuilder`: that type reconstructs a
/// change from Claude Code's old/new text fields, while Codex already supplies
/// a patch. Keeping the two paths separate prevents provider conditionals from
/// leaking into the Claude transcript parser.
nonisolated enum UnifiedDiffParser {
    static func parse(_ patch: String, path: String? = nil) -> FileDiff {
        var rendered: [FileDiff.Line] = []

        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("@@") || line.hasPrefix("diff --git ")
                || line.hasPrefix("index ") || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ") || line == #"\ No newline at end of file"#
            {
                continue
            }

            if line.hasPrefix("+") {
                rendered.append(.init(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                rendered.append(.init(kind: .removed, text: String(line.dropFirst())))
            } else if line.hasPrefix(" ") {
                rendered.append(.init(kind: .context, text: String(line.dropFirst())))
            }
        }

        let truncated = max(0, rendered.count - FileDiffBuilder.maxRenderedLines)
        return FileDiff(
            path: path,
            lines: truncated == 0 ? rendered : Array(rendered.prefix(FileDiffBuilder.maxRenderedLines)),
            truncatedLineCount: truncated
        )
    }
}
