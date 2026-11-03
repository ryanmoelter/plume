import Foundation

/// Text Plume appends to every `claude` it launches, through
/// `--append-system-prompt-file`. A file rather than the text itself, so no
/// multi-line argument has to survive the terminal transport's shell quoting.
nonisolated enum AgentPromptRule {
    /// Nil in a bundle without the resource, which launches without the flag
    /// rather than failing: the CLI refuses to start on an unreadable file.
    static let formattingPath: String? = Bundle.main
        .url(forResource: "plume-formatting-rule", withExtension: "md")
        .map(\.path)

    static func arguments(path: String?) -> [String] {
        guard let path else { return [] }
        return ["--append-system-prompt-file", path]
    }
}
