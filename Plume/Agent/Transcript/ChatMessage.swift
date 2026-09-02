import Foundation

/// One rendered chat message, folded from one or more consecutive transcript
/// lines of the same role.
struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    let id: String
    let role: Role
    var blocks: [ChatBlock]
    let timestamp: Date?
}

enum ChatBlock: Equatable {
    case markdown(String)
    case thinking(String)
    case toolCall(ToolCall)
    /// Something Claude Code injected as a user line — a skill body, a slash
    /// command, shell output. Rendered as a compact marker with the text kept
    /// behind a disclosure rather than shown as the user's prose.
    case injected(InjectedContent, text: String)
}

struct ToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let input: ToolCallInput
    /// Set for the two tools that talk to the user, which render as
    /// themselves instead of as JSON.
    var interactive: InteractiveToolPayload?
    var result: String?
}

/// How a tool call's input should render. Bash's full command renders as
/// shell code instead of raw JSON; everything else keeps the pretty-printed
/// JSON.
enum ToolCallInput: Equatable {
    case code(language: String, text: String)
    case json(String)

    var isEmpty: Bool {
        switch self {
        case .code(_, let text): return text.isEmpty
        case .json(let text): return text.isEmpty || text == "{}"
        }
    }
}
