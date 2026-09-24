import Foundation

/// One rendered chat message, folded from one or more consecutive transcript
/// lines of the same role.
nonisolated struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
        /// A transcript aside — an error, a warning, a compaction boundary.
        /// Rendered full-width as the transcript's own voice, not anyone's
        /// message.
        case notice
    }

    let id: String
    let role: Role
    var blocks: [ChatBlock]
    let timestamp: Date?
    /// Set while the stream is still writing this message.
    var isLive = false
}

nonisolated enum ChatBlock: Equatable {
    case markdown(String)
    case thinking(String)
    case toolCall(ToolCall)
    /// Something Claude Code injected as a user line — a skill body, a slash
    /// command, shell output. Rendered as a compact marker with the text kept
    /// behind a disclosure rather than shown as the user's prose.
    case injected(InjectedContent, text: String)
    case notice(ChatNotice)
    case image(ChatImage)
}

nonisolated struct ToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: ToolCallSummary
    let input: ToolCallInput
    /// Set for the two tools that talk to the user, which render as
    /// themselves instead of as JSON.
    var interactive: InteractiveToolPayload?
    var result: String?
    /// Whether the tool reported failure, from the result's `is_error`. A
    /// rejected permission prompt counts, so this is not only a nonzero exit.
    var didFail = false
    /// Images the tool returned — a screenshot tool returns exactly this.
    var resultImages: [ChatImage] = []
}

/// How a tool call's input should render. Bash's full command renders as
/// shell code instead of raw JSON; everything else keeps the pretty-printed
/// JSON.
nonisolated enum ToolCallInput: Equatable {
    case code(language: String, text: String)
    case json(String)
    /// An `Edit` or `Write`, shown as the change it makes rather than as the
    /// strings that describe it.
    case diff(FileDiff)

    var isEmpty: Bool {
        switch self {
        case .code(_, let text): return text.isEmpty
        case .json(let text):
            // Pretty-printed, so an empty object carries whitespace.
            let compact = text.filter { !$0.isWhitespace }
            return compact.isEmpty || compact == "{}"
        case .diff(let diff): return diff.lines.isEmpty
        }
    }
}
