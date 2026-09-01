import Foundation

/// One rendered chat message, folded from one or more consecutive transcript
/// lines of the same role.
struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id: String
    let role: Role
    var blocks: [ChatBlock]
    let timestamp: Date?
}

enum ChatBlock {
    case markdown(String)
    case thinking(String)
    case toolCall(ToolCall)
}

struct ToolCall: Identifiable {
    let id: String
    let name: String
    let summary: String
    let prettyInput: String
    var result: String?
}
